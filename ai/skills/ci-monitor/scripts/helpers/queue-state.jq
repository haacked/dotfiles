# queue-state.jq - Pure verdict for where a PR sits in a Trunk merge queue.
#
# Trunk does not test a queued PR on the PR's own branch. It opens a draft PR
# from a `trunk-merge/pr-<N>/<uuid>` branch and runs CI there, so the original
# PR's checks stay green while the queue is failing it. States:
#
#   no_queue      no sign of a Trunk merge queue on this repo
#   not_enqueued  Trunk is watching the PR but has not taken it: its status
#                 comment is still the un-submitted control (the "check the box
#                 or comment /trunk merge" one, marked `<!-- Trunk Merge -->`)
#   testing       a trunk-merge branch exists for this PR - CI is running on it
#   blocked       Trunk took the PR and is not testing it now
#   landed        the PR merged
#
# `blocked` spans two situations with opposite consequences: the PR dropped out
# of the queue ("removed from the merge queue because it timed out", "The
# required check … has failed"), and the PR is submitted and waiting to get in
# ("Submitted to Merge by @x. It will be added to the merge queue once…"). All
# were observed live, and the drop phrases are pinned to those exact wordings
# (the rationale sits at the marker definitions below). `blocked_reason` is
# fail-closed: `dropped` (timed out, or a required check failed), `waiting`
# (submitted, not yet taken), `unknown` (anything else, including a body
# matching both ways). This is a deliberate, bounded exception to the
# no-prose rule: the phrases vote on a closed enum, never select an
# action, and every unmatched or contradictory wording lands on `unknown`,
# which callers must treat as push-unsafe and report-only: pushing to a PR
# waiting to get in forfeits its submission just as silently as pushing to
# one mid-test. Only `dropped` unlocks any action, and only behind
# ci-requeue-check.sh. `dropped_marker` names which phrase matched
# (`timed_out` | `check_failed`): a timeout drop can leave zero
# failed checks on the merge PR, which the requeue gate treats differently
# from a check failure.
#
# The state split turns on a machine marker and the existence of a branch; only
# the `blocked_reason` sub-verdict reads prose, bounded to the enum above.
# `comment_after_head` says whether the status was last written after
# the current head, so a caller can tell a live verdict from one that predates the
# developer's latest fix. It compares timestamps only when both are UTC
# (`Z`-suffixed, which is what the GitHub API returns), and null means unknown.
# The head anchor is the commit's committer date, not its push time, which GitHub
# no longer exposes; a commit authored well before it was pushed can therefore
# read as older than a status written before that push. Treat it as a hint.
#
# `enqueue_comments_since_head` counts the exact-body `/trunk merge` comments
# posted after the head commit - the auto-requeue budget ci-requeue-check.sh
# spends. It is null when the head timestamp is not comparable (fail closed:
# the gate treats a null count as unreadable), and a comment timestamp that
# cannot be proven at-or-before the head counts toward the budget -
# over-counting only disables automation, under-counting could arm it.
#
# Input (stdin), one object:
#   { owner, repo, pr_merged, head_sha, head_committed_at, merge_branch,
#     refs_for_pr: [<git ref strings>], queue_active: <bool>,
#     merge_pr_from_ref: <number|null>,
#     last_queue_comment: {created_at, updated_at, html_url, body} | null,
#     pr_comments: [{body, created_at}] }
# Output: { state, blocked_reason, dropped_marker, queue_active, merge_branch,
#           merge_pr, merge_pr_source, comment_after_head,
#           enqueue_comments_since_head, head_sha, head_committed_at,
#           last_queue_comment }

# Marker on Trunk's un-submitted control comment. Trunk edits this one comment in
# place as the PR moves through the queue, and the marker is gone once it has.
def CONTROL_MARKER: "<!-- Trunk Merge -->";

# Fixed phrases Trunk writes into its status comment, observed live. They vote
# on blocked_reason, a closed enum - prose still never selects an action. jq's
# `test` does not let `.` cross newlines, so the failure phrase must sit on one
# line, as observed; anything unmatched or contradictory lands on "unknown".
# The timeout marker is the whole observed sentence rather than its "removed
# from the merge queue" family: an unobserved removal wording (a human's
# web-app Remove, a label removal) must read unknown, not dropped. A newly
# observed drop wording gets its own marker and enum value here, judged in
# the requeue gate on its own semantics - never folded into an existing one.
def WAITING_MARKER: "will be added to the merge queue";
def DROPPED_TIMEOUT_MARKER: "removed from the merge queue because it timed out";
def DROPPED_CHECK_FAILED_RE: "[Tt]he required check .+ has failed";

# The GitHub API returns UTC (Z-suffixed) timestamps; only those are safe to
# compare as strings.
def is_utc: type == "string" and test("Z$");

# An enqueue comment is the exact `/trunk merge` body and nothing more, so
# Trunk's control comment - which merely mentions the command - never counts.
# Any author counts on purpose: a third party spamming the exact body can only
# exhaust the budget, i.e. disable automation, never arm anything.
def ENQUEUE_COMMENT_RE: "^[[:space:]]*/trunk merge[[:space:]]*$";

# The merge PR number as the bot itself linked it, for when the branch is already
# gone. Only links pointing at this same repo count, so a link in the body cannot
# redirect the caller elsewhere, and only the number is taken - never the prose.
def merge_pr_from_body($owner; $repo):
  [ scan("https?://(?:www\\.)?github\\.com/([^/[:space:])]+)/([^/[:space:])]+)/pull/([0-9]+)") ]
  | map(select((.[0] | ascii_downcase) == ($owner | ascii_downcase)
           and (.[1] | ascii_downcase) == ($repo  | ascii_downcase)))
  | last
  | if . == null then null else (.[2] | tonumber) end;

. as $in
| ($in.refs_for_pr // []) as $refs
| ($in.last_queue_comment // null) as $comment
| (($comment.body // "") | merge_pr_from_body($in.owner; $in.repo)) as $pr_from_comment
| ($comment != null and (($comment.body // "") | contains(CONTROL_MARKER) | not)) as $engaged
| (($comment.updated_at // "") as $written
   | ($in.head_committed_at // "") as $committed
   | if ($written | is_utc) and ($committed | is_utc)
     then $written > $committed
     else null
     end) as $comment_after_head
| ((($in.queue_active // false) or ($comment != null)) as $active
   | if ($active | not) then "no_queue"
     elif ($in.pr_merged // false) then "landed"
     elif ($refs | length) > 0 then "testing"
     elif $engaged then "blocked"
     else "not_enqueued"
     end) as $state
# Only blocked earns a reason. check_failed outranks timed_out when a body
# carries both drop phrases: it is the stricter marker (the requeue gate
# demands an identifiable merge PR to triage for it).
| (if $state != "blocked" then {reason: null, marker: null}
   else ($comment.body // "") as $body
   | ($body | contains(WAITING_MARKER)) as $waiting
   | ($body | contains(DROPPED_TIMEOUT_MARKER)) as $timed_out
   | ($body | test(DROPPED_CHECK_FAILED_RE)) as $check_failed
   | if $waiting and ($timed_out or $check_failed) then {reason: "unknown", marker: null}
     elif $check_failed then {reason: "dropped", marker: "check_failed"}
     elif $timed_out then {reason: "dropped", marker: "timed_out"}
     elif $waiting then {reason: "waiting", marker: null}
     else {reason: "unknown", marker: null}
     end
   end) as $blocked
# The budget count: enqueue comments not provably at-or-before the head count
# toward it. Z-to-Z string compares only, like comment_after_head above.
| (($in.head_committed_at // "") as $committed
   | if ($committed | is_utc)
     then ([ ($in.pr_comments // [])[]
             | select((.body // "") | test(ENQUEUE_COMMENT_RE))
             | .created_at
             | select((is_utc and (. <= $committed)) | not) ]
           | length)
     else null
     end) as $enqueue_comments_since_head
| {
    state: $state,
    blocked_reason: $blocked.reason,
    dropped_marker: $blocked.marker,
    queue_active: (($in.queue_active // false) or ($comment != null)),
    merge_branch: (($in.merge_branch // "") | if . == "" then null else . end),
    merge_pr: (($in.merge_pr_from_ref // null) // $pr_from_comment),
    merge_pr_source: (if ($in.merge_pr_from_ref // null) != null then "branch"
                      elif $pr_from_comment != null then "comment"
                      else null end),
    comment_after_head: $comment_after_head,
    enqueue_comments_since_head: $enqueue_comments_since_head,
    head_sha: ($in.head_sha // null),
    head_committed_at: ($in.head_committed_at // null),
    last_queue_comment: (if $comment == null then null
                         else {created_at: $comment.created_at,
                               updated_at: $comment.updated_at,
                               url: $comment.html_url,
                               body: $comment.body}
                         end)
  }
