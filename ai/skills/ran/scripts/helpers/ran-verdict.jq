# Decide, for each pipeline step, whether it has run and whether its run still
# covers the branch as it stands now.
#
# The log records the sha at the moment a command was invoked, but most of these
# steps commit after they run, so a step's own work almost always lands at a
# later sha than the one it logged. Comparing the logged sha to HEAD would
# therefore report a finished branch as entirely stale. Attribution answers the
# question the sha cannot: each commit belongs to the most recent command that
# preceded it, and a step is stale only when a commit after its last run belongs
# to an earlier step or to no command at all.
#
# A step whose result can be read directly reads it instead of the log: `tree`
# reads the working tree, `pr` reads the branch's PR, and `ci` reads the checks
# on the PR's head. A `threads` step is a `completion` step that the PR's review
# comments can also make stale. When GitHub did not answer, `pr` and `ci` read
# the log and `threads` reads only the completion records.
#
# Args: $head, $branch, $window (seconds), $steps [{step,evidence,optional}],
#       $history {commits [{sha,ts,rewritten}] oldest first,
#                 renamed {old full sha: current short sha},
#                 gone [old full shas with no replacement]},
#       $entries [{ts,step,sha,status}], $dirty (uncommitted file count),
#       $github (whether GitHub answered),
#       $pr null | {number, state, draft, head, ahead, ci, more_threads,
#                   unanswered [epoch]}
#           ahead is how many commits HEAD is past the PR head, or null when
#           HEAD does not contain it. unanswered holds, per unresolved thread
#           whose latest comment is someone else's, that comment's time.
#           more_threads says the PR has threads past the first 100 read.
# Out:  {branch, head, github,
#        rows[{step,status,at,sha,gone,commits,detail,reasons}],
#        outstanding[], fell_back[], extras[]}
#       status is fresh | stale | missing | pending | running

include "text";

$history.commits as $commits
| ($entries | map(. + {ets: (.ts | fromdateiso8601)}) | sort_by(.ets)) as $log
| ($steps | map(.step)) as $order
| ($order | to_entries | map({key: .value, value: .key}) | from_entries) as $rank
| ($steps | map({key: .step, value: .}) | from_entries) as $decl

| def evidence($step):
    $decl[$step].evidence as $e
    | if $github then $e
      elif $e == "pr" or $e == "ci" then "log"
      elif $e == "threads" then "completion"
      else $e
      end;

# The entries that count as evidence for a step. A `completion` step counts only
# the records its skill wrote when it finished, because the hook writes its own
# before the command runs; every other step counts any record of the command.
# Entries predating the status field carry none, so they never satisfy a
# `completion` step, and a branch logged before this reads as needing the review.
  def evidence_for($step):
    (evidence($step) | . == "completion" or . == "threads") as $needs_done
    | [$log[] | select(.step == $step and (.status == "done" or ($needs_done | not)))];

# A rebase replaces the commit a log entry recorded. The row then shows the
# commit that replaced it, when one has the same patch. Otherwise it shows the
# recorded sha and says the branch no longer holds it.
  def current_sha:
    . as $logged
    | if $logged == null then {sha: null}
      else ([$history.renamed | to_entries[] | select(.key | startswith($logged)) | .value] | first)
           as $replacement
         | if $replacement != null then {sha: $replacement}
           else {sha: $logged, gone: any($history.gone[]; startswith($logged))}
           end
      end;

  ($order | map(
    . as $step
    | {key: $step,
       value: (evidence($step) as $e
               | if $e == "commits" or $e == "tree" then ($commits | length) > 0
                 elif $e == "pr" then $pr != null and $pr.state != "CLOSED"
                 elif $e == "ci" then $pr.ahead == 0 and $pr.ci == "SUCCESS"
                 else (evidence_for($step) | length) > 0
                 end)}) | from_entries) as $ran

# Due once the last required step before it has run; before that it is not yet
# its turn. Skipping an optional step must not silence the rest.
| def due($step):
    ([$order[:$rank[$step]][] | select($decl[.].optional | not)] | last) as $prev
    | $prev != null and $ran[$prev] and ($decl[$step].optional | not);

# Each commit belongs to the most recent command logged before it, but only if
# that command was recent enough to have produced it: a step commits within
# minutes of being invoked, so a commit long after the last command is one a
# person made by hand, and work made by hand is what a step needs to see again.
# A commit belongs to a step that had started, so attribution reads the `started`
# records and skips the `done` ones: work landing after a step reported finished
# is work that step never saw, and crediting it there would keep the step fresh
# over a commit nobody reviewed. Records predating the status field carry none,
# so they still attribute exactly as they did.
  ($commits | map(
    . as $c
    | ([$log[] | select(.status != "done" and .ets <= $c.ts)] | last) as $e
    | (if $e == null or ($c.ts - $e.ets) > $window then "manual" else $e.step end) as $step
    | $c + {step: $step,
            cause: (if $step != "manual" then "by \($step)"
                    elif $c.rewritten then "rewritten"
                    else "by hand" end)}
  )) as $attributed

# Movement after a step's last run is only a problem when it came from an
# earlier step or from no command; later steps are the pipeline moving on.
| def unseen($step; $since):
    [$attributed[]
     | select(.ts > $since
              and (.step == "manual" or (($rank[.step] // 1e9) < $rank[$step])))];

  def reasons($unseen):
    $unseen | group_by(.cause)
    | map((if length == 1 then .[0].sha else plural(length; "commit") end) + " " + .[0].cause);

  ($order | map(
    . as $step
    | evidence($step) as $e
    | (if $e == "commits"
        then {status: (if ($commits | length) > 0 then "fresh" else "pending" end),
              sha: ($commits | last | .sha), commits: ($commits | length)}
      elif $e == "tree"
        then (if $dirty > 0
                then {status: "stale", detail: "\(plural($dirty; "file")) uncommitted"}
              elif ($commits | length) > 0
                then {status: "fresh", detail: "nothing uncommitted"}
              else {status: "pending"}
              end)
      elif $e == "pr"
        then (if $pr == null
                then {status: (if due($step) then "missing" else "pending" end), detail: "no PR"}
              elif $pr.state == "CLOSED"
                then {status: "missing", detail: "#\($pr.number) closed"}
              else {status: "fresh",
                    detail: "#\($pr.number) \(if $pr.state == "MERGED" then "merged"
                                              elif $pr.draft then "draft"
                                              else "open" end)"}
              end)
      elif $e == "ci"
        then (if $pr == null
                then {status: "pending", detail: "no PR"}
              elif $pr.ahead == null
                then {status: "stale", detail: "PR head \($pr.head) is not HEAD"}
              elif $pr.ahead > 0
                then {status: "stale", detail: "\(plural($pr.ahead; "commit")) not pushed"}
              else ({SUCCESS: ["fresh", "passed"], PENDING: ["running", "running"],
                     EXPECTED: ["running", "running"], FAILURE: ["stale", "failing"],
                     ERROR: ["stale", "failing"]}[$pr.ci // ""]
                    // ["pending", "no checks"]) as [$status, $word]
                   | {status: $status, detail: "\($word) on \($pr.head)"}
              end)
      else
          (evidence_for($step) | last) as $last
          # address-pr-reviews leaves the threads it fixed unresolved. It also
          # leaves a dismissed human comment unresolved for the reviewer to
          # answer. The pass fetches comments when it starts and records `done`
          # when it ends. A comment posted after the start may be one it did
          # not see. A Codex run has no started record, so its `done` time
          # stands in. The PR alone never makes the row fresh.
          | (if $e == "threads"
             then ([$log[] | select(.step == $step and .status != "done"
                                    and .ets <= ($last.ets // 0))] | last | .ets) as $started
                  | [($pr.unanswered // [])[] | select(. > ($started // $last.ets // 0))] as $new
                  | (if ($new | length) > 0 then [plural($new | length; "new review comment")] else [] end)
                    + (if $pr.more_threads then ["over 100 review threads, not all read"] else [] end)
             else []
             end) as $open
          | if $last == null
              then {status: (if due($step) or ($open | length) > 0 then "missing" else "pending" end),
                    reasons: $open}
            else
              (reasons(unseen($step; $last.ets)) + $open) as $why
              | ([$attributed[] | select(.step == $step)] | last) as $mine
              | {status: (if ($why | length) > 0 then "stale" else "fresh" end),
                 at: $last.ts, reasons: $why}
                + (if $mine != null then {sha: $mine.sha} else $last.sha | current_sha end)
            end
      end)
    | {step: $step, status, at, sha, gone: (.gone // false), commits, detail, reasons: (.reasons // [])}
  )) as $rows

| {branch: $branch,
   head: $head,
   github: $github,
   rows: $rows,
   outstanding: [$rows[] | select(.status == "missing" or .status == "stale") | .step],
   fell_back: [$order[] | select(evidence(.) != $decl[.].evidence)],
   # Logged, but not positions in the sequence: orchestration and wrap-up.
   extras: ([$log[] | select($rank[.step] == null) | .step] | unique)}
