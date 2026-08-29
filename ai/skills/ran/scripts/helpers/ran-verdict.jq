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
# Args: $head, $branch, $window (seconds), $steps [{step,evidence,optional}],
#       $commits [{sha,ts}] oldest first, $entries [{ts,step,sha,status}]
# Out:  {branch, head, rows[{step,status,at,sha,commits}], outstanding[], extras[]}
#       status is fresh | stale | missing | pending

($entries | map(. + {ets: (.ts | fromdateiso8601)}) | sort_by(.ets)) as $log
| ($steps | map(.step)) as $order
| ($order | to_entries | map({key: .value, value: .key}) | from_entries) as $rank
| ($steps | map({key: .step, value: .}) | from_entries) as $decl

# The entries that count as evidence for a step. A `completion` step counts only
# the records its skill wrote when it finished, because the hook writes its own
# before the command runs; every other step counts any record of the command.
# Entries predating the status field carry none, so they never satisfy a
# `completion` step, and a branch logged before this reads as needing the review.
| def evidence_for($step):
    [$log[] | select(.step == $step
                     and (if $decl[$step].evidence == "completion"
                          then .status == "done" else true end))];

  ($steps | map(
    . as $s
    | {key: $s.step,
       value: (if $s.evidence == "commits"
               then ($commits | length) > 0
               else (evidence_for($s.step) | length) > 0
               end)}) | from_entries) as $ran

# Each commit belongs to the most recent command logged before it, but only if
# that command was recent enough to have produced it: a step commits within
# minutes of being invoked, so a commit long after the last command is one a
# person made by hand, and work made by hand is what a step needs to see again.
# A commit belongs to a step that had started, so attribution reads the `started`
# records and skips the `done` ones: work landing after a step reported finished
# is work that step never saw, and crediting it there would keep the step fresh
# over a commit nobody reviewed. Records predating the status field carry none,
# so they still attribute exactly as they did.
| ($commits | map(
    . as $c
    | ([$log[] | select(.status != "done" and .ets <= $c.ts)] | last) as $e
    | {sha: $c.sha, ts: $c.ts,
       step: (if $e == null or ($c.ts - $e.ets) > $window then "manual" else $e.step end)}
  )) as $attributed

| ($order | map(
    . as $step
    | $rank[$step] as $myrank
    | (evidence_for($step) | last) as $last
    | (if $decl[$step].evidence == "commits"
        then {status: (if ($commits | length) > 0 then "fresh" else "pending" end),
              at: null, sha: ($commits | last | .sha), commits: ($commits | length)}
      elif $last == null
        then ([$order[:$myrank][] | select($decl[.].optional | not)] | last) as $prev
          # Due once the last required step before it has run; before that it is
          # not yet its turn. Skipping an optional step must not silence the rest.
          | {status: (if ($prev != null and $ran[$prev]
                          and ($decl[$step].optional | not))
                      then "missing" else "pending" end),
             at: null, sha: null, commits: null}
      else
          # Movement after the last run is only a problem when it came from an
          # earlier step or from no command; later steps are the pipeline moving on.
          (any($attributed[];
               .ts > $last.ets
               and (.step == "manual" or (($rank[.step] // 1e9) < $myrank)))) as $regressed
          | ([$attributed[] | select(.step == $step)] | last) as $mine
          | {status: (if $regressed then "stale" else "fresh" end),
             at: $last.ts, sha: (($mine // $last) | .sha), commits: null}
      end)
    | . + {step: $step}
  )) as $rows

| {branch: $branch,
   head: $head,
   rows: $rows,
   outstanding: [$rows[] | select(.status == "missing" or .status == "stale") | .step],
   # Logged, but not positions in the sequence: orchestration and wrap-up.
   extras: ([$log[] | select($rank[.step] == null) | .step] | unique)}
