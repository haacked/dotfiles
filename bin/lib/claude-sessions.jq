# jq functions for bin/claude-sessions, and the programs behind --plan and
# --render. Both programs read the facts array that --json prints.
#
# plan decides each session's bucket and next step where the facts alone can,
# and returns the checks that only a model can answer.
# render($answers; $act) applies the model's answers to the same rules and
# returns the markdown table, or the problems it found in the answers.

def minutes_since: (now * 1000 - .) / 60000 | floor | if . < 0 then 0 else . end;
def epoch_ms: sub("\\.[0-9]+Z$"; "Z") | fromdateiso8601 * 1000;
def repo: capture("github\\.com/(?<r>[^/]+/[^/]+)/pull/").r;
# A stack edge has no URL until a lookup finds its PR, so its key is the repo
# and the branch.
def edge_key($repo): .url // "\($repo) \(.base)";
def age: if . == null then null elif . < 60 then "\(.)m" elif . < 2880 then "\(. / 60 | floor)h" else "\(. / 1440 | floor)d" end;
def queued: . != null and . != "Removed from Trunk Queue" and . != "unknown";
def uniq_by(f): reduce .[] as $x ([]; if any(.[]; f == ($x | f)) then . else . + [$x] end);

# Each PR that the text names as a URL, owner/repo#N, or #N, as {repo, pr}.
# repo is null for #N. $guard is a regex that must match just before #N or
# owner/repo#N.
def pr_refs($guard):
  scan("https://github\\.com/([\\w.-]+/[\\w.-]+)/pull/([0-9]+)|\($guard)(?:([\\w.-]+/[\\w.-]+))?#([0-9]+)")
  | {repo: (.[0] // .[2]), pr: (.[1] // .[3] | tonumber)};

# A check that the model has not answered yet is null, so the rules use
# three-valued logic.
def and3($a; $b): if $a == false or $b == false then false elif $a == null or $b == null then null else true end;
def not3: if . == null then null else not end;
def any3(f): reduce f as $x (false; if . == true or $x == true then true elif . == null or $x == null then null else false end);

def pr_word: .pr.status // "" | split(", ")[0] // "";
def finished: pr_word | IN("Merged", "Closed");
def stale: (.idle // 0) > 2880;
def dirty: (.dirty // 0) > 0;
def edge_label: if .pr then "#\(.pr)" else .base end;
def dependency: .state == "OPEN" or .state == null;
def exited:
  .tail.user // ""
  | test("<command-name>/(exit|quit)</command-name>") or (gsub("^\\s+|\\s+$"; "") | IN("/exit", "/quit"));
def known_poll: .tool == "Bash" and (.input // "" | test("ci-check-status|wait-for-pending-reviews|\\bgh (pr checks|run watch)\\b"));
def resolving: .input // "" | test("\\b(rebase|merge|restack)\\b|resolve-conflicts"; "i");
def busy_base($by):
  if .pr.mergeable == "CONFLICTING"
  then first(.depends[]? | select(.via == "stack" and .session != null and $by[.session].status == "busy")) // null
  else null end;
def deploy_label: edge_label + (if .merged then " (merged \(.merged | age) ago)" else "" end);

# The step for a busy session whose running call is a known poll. It names the
# PR from the command, or else the session's own PR.
def poll_step($stuck):
  (first(.running.input | capture("(ci-check-status\\S*|gh pr checks|wait-for-pending-reviews\\S*\\s+\\S+)\\s+(?<n>[0-9]+)").n)
    // .pr.number) as $n
  | if .running.input | test("wait-for-pending-reviews") then
      (if $n then " of #\($n)" else "" end) as $of
      | if $stuck then "check whether the wait for review\($of) is stuck" else "review\($of)" end
    else
      (if $n then " on #\($n)" else "" end) as $on
      | if $stuck then "check whether the CI poll\($on) is stuck" else "CI\($on)" end
    end;

# The live sessions whose open or closed PR the session's last assistant text
# names, as {session, pr, url, state}. A stale session's tail is too old to
# say what it waits on now. A finished session waits on nothing.
def candidates($all):
  if .self or stale or finished then []
  else
    [.depends[]?.url // empty | ascii_downcase] as $known
    | (.pr.url // "" | ascii_downcase) as $own
    # A tail skips #N inside a word, such as a URL fragment like page#12.
    | [.tail.assistant // "" | pr_refs("(?<![\\w./-])")
        | (if .repo then "https://github.com/\(.repo)/pull/\(.pr)" | ascii_downcase else null end) as $url
        | .pr as $n
        | [$all[] | select(.pr != null and (if $url then (.pr.url | ascii_downcase) == $url else .pr.number == $n end))]
        # A bare #N that live sessions in two repos share names neither.
        | select(map(.pr.url | ascii_downcase) | unique | length == 1)
        | .[0]
        | select((.pr.url | ascii_downcase) as $u
            | $u != $own and (.pr.state | IN("OPEN", "CLOSED")) and ($u | IN($known[]) | not))
        | {session: .name, pr: .pr.number, url: .pr.url, state: .pr.state}]
    | uniq_by(.session)
  end;

# The session's depends entries, then its candidates. accepted is true for a
# depends entry. A candidate's accepted is null in a plan, which has no answers
# yet. In a render it says whether the answers name the candidate.
def edges($cands; $ans):
  [(.depends // [])[] + {accepted: true},
   ($cands[] | . + {via: "inferred", deploy: false,
     accepted: (if $ans == null then null else .session | IN($ans.edges[]?) end)})];

def yes($ans; $id):
  if $ans == null then null else $ans[$id] | if type == "string" then . != "" else . == true end end;

def approved_step:
  if .pr.queue == "unknown" then "check whether Trunk queued it; its queue status did not load"
  elif .pr.commenters == null then "check for reviewer comments, then enqueue; they did not load"
  elif .pr.commenters != [] then "read the comments from \(.pr.commenters | join(" and ")), then enqueue"
  else "enqueue the PR" end;

# Each rule is {bucket, fit} plus one of: step (fixed text), write (the
# model's step answer gives the text), or check (the answer to that check
# gives the text). A rule with unless fits only when that check's answer is no.
# reads names what the model reads to answer the rule's check.
def busy_rules($by; $ans):
  busy_base($by) as $bb
  | .running as $r
  | {bucket: "done", fit: finished,
      step: "PR \(pr_word | ascii_downcase); \(if dirty then "check its uncommitted changes" else "archive the worktree" end) once it stops"},
    {bucket: "needs-you", fit: exited, step: "close its tab"},
    {bucket: "held", fit: ($bb != null), step: "rebase onto \($bb | edge_label) once it settles"},
    {bucket: "needs-you", fit: (.pr.mergeable == "CONFLICTING" and ($r | resolving | not)), step: "rebase; the PR conflicts with its base"},
    if $r == null then {bucket: "working", fit: true, step: "working"}
    elif ($r | known_poll) then
      if ($r.minutes // 0) > 60 then {bucket: "needs-you", fit: true, step: poll_step(true)}
      else {bucket: "outside", fit: true, step: poll_step(false)} end
    else
      {bucket: "needs-you", check: "stuck", reads: "running", fit: yes($ans; "stuck")},
      {bucket: "outside", check: "polling", reads: "running", fit: yes($ans; "polling")},
      {bucket: "working", fit: true, write: "running"}
    end;

# A blank tail answers no to every check that reads it.
def idle_rules($by; $ans; $edges):
  busy_base($by) as $bb
  | (.tail.assistant // "" | test("\\S") | not) as $blank
  | [$edges[] | select(.accepted == true)] as $sure
  | (first($sure[] | select(.via == "stack" and .state == "MERGED")) // null) as $base_merged
  | (first($sure[] | select(.state == "CLOSED")) // null) as $closed
  | (first($sure[] | select(.deploy and .state == "MERGED") | deploy_label) // null) as $deployed
  | (first($sure[] | select(dependency)) // null) as $dep
  | any3($edges[] | and3(.accepted; dependency)) as $has_dep
  | def said($id): if $blank then false else yes($ans; $id) end;
    {bucket: (if dirty then "needs-you" else "done" end),
      fit: (finished and .waiting == null and .signing == null),
      step: (if dirty then "commit or discard the uncommitted changes" else "archive the worktree" end)},
    {bucket: "needs-you", fit: (.waiting != null), write: "prompt"},
    {bucket: "needs-you", fit: (.signing == "blocked"), step: "retry the commit; signing failed"},
    {bucket: "needs-you", fit: (.pr.mergeable == "CONFLICTING" and $bb == null), step: "rebase; the PR conflicts with its base"},
    {bucket: "needs-you", fit: (.pr.queue == "Removed from Trunk Queue"), step: "find out why Trunk removed the PR"},
    {bucket: "needs-you", fit: and3(pr_word == "Approved" and (.pr.queue | . == null or . == "unknown"); $has_dep | not3),
      step: approved_step},
    {bucket: "needs-you", fit: ($base_merged != null), step: "retarget the PR; its base \($base_merged | edge_label) merged"},
    {bucket: "needs-you", fit: any3($edges[] | and3(.accepted; .state == "CLOSED")),
      step: "decide what replaces \($closed | edge_label), which closed unmerged"},
    {bucket: "needs-you", unless: "waits_elsewhere", reads: "tail",
      fit: and3(pr_word == "Changes requested"; said("waits_elsewhere") | not3), step: "address the requested changes"},
    {bucket: "needs-you", check: "question", reads: "tail", fit: said("question")},
    (select(.status == "idle" and .pr.queue == null and $bb == null)
      | {bucket: "continue", check: "offer", reads: "tail", fit: said("offer")}),
    {bucket: "outside", fit: (.pr.queue | queued), step: "Trunk queue on #\(.pr.number)"},
    {bucket: "outside", fit: (pr_word | IN("Review required", "Not approved")), step: "review of #\(.pr.number)"},
    {bucket: "outside", unless: "past_deploy", reads: "tail",
      fit: and3($deployed != null; said("past_deploy") | not3), step: "deploy of \($deployed)", deploy: $deployed},
    {bucket: "outside", check: "outside", reads: "tail", fit: said("outside")},
    {bucket: "held", fit: $has_dep,
      step: (if $bb then "rebase onto \($bb | edge_label) once it settles" else "waits on \($dep | edge_label)" end)},
    {bucket: "stale", fit: stale, step: "idle for \(.idle | age); resume or close it"},
    {bucket: "needs-you", fit: true, step: "read its last reply and decide what's next"};

# A stale session skips every rule that reads its tail, because a tail written
# days ago says nothing about the session's state now.
def rules($by; $ans; $edges):
  if .status == "busy" then [busy_rules($by; $ans)]
  elif stale then [idle_rules($by; $ans; $edges) | select(.reads != "tail")]
  else [idle_rules($by; $ans; $edges)] end;

def bool_checks: ["waits_elsewhere", "past_deploy"];

# The session's plan entry, or nothing when the facts decide everything. The
# walk asks each check up to the first rule that fits for certain.
def plan_entry($by; $edges):
  (rules($by; null; $edges) | map(select(.fit != false)) | .[:map(.fit) | index(true) + 1]) as $reach
  | [$reach[] | select(.fit == null)] as $open
  | ([$open[] | .check // .unless // empty] | uniq_by(.)) as $ask
  | ([$reach[] | .write // empty] | first) as $write
  | [$edges[] | select(.accepted == null) | {session, pr}] as $cands
  | select($ask != [] or $cands != [] or $write)
  | {name, pr: (if .pr then "#\(.pr.number) \(.pr.status)" else null end)}
    + ({ask: $ask, edges: $cands, write: $write,
        waiting: (if $write == "prompt" then .waiting else null end),
        deploy: ([$open[] | .deploy // empty] | first),
        running: (if $write or any($open[]; .reads == "running") then .running else null end),
        tail: (if any($open[]; .reads == "tail") or $cands != [] or $write == "prompt" then .tail.assistant else null end)}
      | with_entries(select(.value != null and .value != [])));

def plan:
  . as $all
  | INDEX(.name) as $by
  | {sessions: [.[] | select(.self | not) | plan_entry($by; edges(candidates($all); null))]};

def object_or_empty: if type == "object" then . else {} end;

def answer_errors($plans; $given):
  $given | to_entries[] | .key as $n | .value as $v | $plans[$n] as $p
  | if $p == null then "\($n): nothing was asked about this session"
    elif ($v | type) != "object" then "\($n): the answers must be a JSON object"
    else
      $v | to_entries[] | .key as $k | .value as $x
      | if (($k | IN($p.ask[]?)) or ($k == "edges" and $p.edges) or ($k == "step" and $p.write)) | not then
          "\($n): \($k) was not asked"
        elif $k == "edges" then
          if ($x | type) != "array" then "\($n): edges must be a list of session names"
          else $x[] | select(IN($p.edges[].session) | not) | "\($n): edges names \(.), which is not a candidate" end
        elif $k | IN(bool_checks[]) then
          if $x == null or ($x | type) == "boolean" then empty else "\($n): \($k) must be true or false" end
        elif $x == null or $x == false then empty
        elif ($x | type) != "string" or $x == "" then "\($n): \($k) must be the next step, or false"
        elif $x | test("[[:cntrl:]]") then "\($n): \($k) must be one line of text"
        elif ($x | length) >= 70 then "\($n): \($k) is \($x | length) characters; keep it under 70"
        else empty end
    end;

def up($parents): ., ($parents[.].session // empty | up($parents));

# The parent of each row that nests under another, as {<name>: <owner>}.
# Each row takes its first owner that would not close a loop.
def nest:
  reduce .[] as $r ({};
    . as $parents
    | (first($r.owners[] | select(any(.session | up($parents); . == $r.name) | not)) // null) as $o
    | if $o then .[$r.name] = $o else . end);

# Each child's name cell, depth first, drawn as `tree` draws it.
def tree($kids; $parents; $indent):
  ($kids[.] // []) as $ks
  | range($ks | length) as $i
  | $ks[$i] as $c
  | ($i == ($ks | length) - 1) as $last
  | {name: $c, cell: ($indent + (if $last then "└" else "├" end) + (if $parents[$c].inferred then "? " else " " end) + $c)},
    ($c | tree($kids; $parents; $indent + (if $last then "  " else "│ " end)));

def pr_cell:
  if .pr == null then "-"
  else
    .pr as $pr
    | ($pr.status // "") as $words
    | "[#\($pr.number)](\($pr.url)) "
      + if ($words | startswith("Approved")) | not then $words
        else
          (if ($pr.approvers // []) != [] then "Approved by \($pr.approvers | join(" and "))\($words[8:])" else $words end)
          + if ($pr.commenters // []) != [] then "; comments from \($pr.commenters | join(" and "))"
            elif $pr.commenters == null and $pr.state == "OPEN" then "; comments did not load"
            else "" end
        end
  end;

def names($label): if $label | startswith("#") then test($label + "(?![0-9])") else contains($label) end;
def oneline: gsub("\\s*[\\r\\n]\\s*"; " ");
def cell: oneline | gsub("\\|"; "\\|");

def groups:
  [["needs-you", "Needs you"], ["continue", "Claude can continue"], ["outside", "Waiting on something outside"],
   ["working", "Working"], ["done", "Done"], ["stale", "Stale"]];

def render($raw; $act):
  . as $all
  | INDEX(.name) as $by
  | ($raw | object_or_empty) as $answers
  | ($answers.sessions | object_or_empty) as $given
  | map(select(.self | not)) as $rows
  | ($rows | INDEX(.name)) as $row_by
  | [$rows[]
      | ($given[.name] | object_or_empty) as $ans
      | candidates($all) as $cands
      | edges($cands; $ans) as $edges
      | first(rules($by; $ans; $edges)[] | select(.fit == true)) as $rule
      | {name, s: ., rule: $rule,
         plan: (plan_entry($by; edges($cands; null)) // null),
         bucket: $rule.bucket,
         step: (if $rule.check then $ans[$rule.check] elif $rule.write then $ans.step else $rule.step end),
         deps: [$edges[] | select(.accepted == true and dependency)]}
      | .owners = [.name as $me | .deps[] | select(.session != null and .session != $me and $row_by[.session] != null)
          | {session, inferred: (.via == "inferred"), label: edge_label}]] as $decided
  | [ (if $raw | type == "object" then empty else "the answers must be a JSON object" end),
      ($raw | objects | keys[] | select(IN("offline", "sessions") | not) | "\(.) is not offline or sessions"),
      ($raw | objects | .sessions | select(type | IN("object", "null") | not)
        | "sessions must be a JSON object keyed by session name"),
      (if ($answers.offline // 0 | type == "number" and . >= 0 and . == floor) then empty else "offline must be a whole number" end),
      answer_errors([$decided[].plan | values] | INDEX(.name); $given),
      ($decided[] | select(.rule.write and (.step | type != "string" or . == "")) | "\(.name): step is missing")
    ] as $errors
  | if $errors != [] then {errors: $errors}
    else
      ($decided | nest) as $parents
      | (reduce $decided[] as $r ({}; if $parents[$r.name] then .[$parents[$r.name].session] += [$r.name] else . end)) as $kids
      | ($decided | INDEX(.name)) as $dec
      | (groups | map(.[0])) as $rank
      | [$decided | to_entries[] | select($parents[.value.name] == null)
          | .key as $order | .value.name as $root
          | [{name: $root, cell: $root}, ($root | tree($kids; $parents; ""))] as $block
          | {order: $order, rows: $block,
             group: ([$block[] | $dec[.name].bucket as $b
               | if $b != "held" then $rank | index($b) elif .name == $root then $rank | index("outside") else empty end] | min)}]
      | sort_by(.group, -(.rows | length), .order) as $blocks
      | (if $rows == [] then ["No sessions are live."]
         else
           ["| Session | PR | Next step |", "| --- | --- | --- |"]
           + [groups | to_entries[] | .key as $g
               | [$blocks[] | select(.group == $g)] as $in
               | select($in != [])
               | "| **\(.value[1])** | | |",
                 ($in[].rows[]
                   | $dec[.name] as $d
                   | ($parents[.name].label // null) as $shown
                   | ($d.step + ([$d.deps[] | edge_label] | uniq_by(.)
                       | map(select(. != $shown) | . as $l | select($d.step | names($l) | not) | "; on \(.)") | join(""))) as $step
                   | "| \(.cell | sub("^(?<s> +)"; "\(.s | gsub(" "; "⠀"))") | cell) | \($d.s | pr_cell | cell) | \($step | cell) |")]
         end)
        + (($answers.offline // 0) as $n
            | if $n == 1 then ["", "1 Remote Control session is offline."]
              elif $n > 1 then ["", "\($n) Remote Control sessions are offline."]
              else [] end)
        + (if $act | not then []
           else [$blocks[].rows[] | $dec[.name] | select(.bucket == "continue") | "- \(.name | oneline): \(.step | oneline)"] as $act_rows
             | if $act_rows == [] then ["", "No session can continue on its own."]
               else ["", "Sessions that Claude can continue:"] + $act_rows end
           end)
      | {text: join("\n")}
    end;
