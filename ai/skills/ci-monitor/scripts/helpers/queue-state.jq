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
# of the queue ("removed from the merge queue because it timed out"), and the PR
# is submitted and waiting to get in ("Submitted to Merge by @x. It will be added
# to the merge queue once…"). Both were observed live. Trunk separates them only
# in the prose of its status comment, and reading that prose is exactly what this
# verdict refuses to do, so it does not guess. A caller deciding whether a push is
# safe must therefore treat `blocked` as unsafe: pushing to a PR waiting to get in
# forfeits its submission just as silently as pushing to one mid-test. A caller
# reporting to a human should quote the comment and let them read it.
#
# The split turns on a machine marker and the existence of a branch, never on the
# bot's prose. `comment_after_head` says whether the status was last written after
# the current head, so a caller can tell a live verdict from one that predates the
# developer's latest fix. It compares timestamps only when both are UTC
# (`Z`-suffixed, which is what the GitHub API returns), and null means unknown.
# The head anchor is the commit's committer date, not its push time, which GitHub
# no longer exposes; a commit authored well before it was pushed can therefore
# read as older than a status written before that push. Treat it as a hint.
#
# Input (stdin), one object:
#   { owner, repo, pr_merged, head_sha, head_committed_at, merge_branch,
#     refs_for_pr: [<git ref strings>], queue_active: <bool>,
#     merge_pr_from_ref: <number|null>,
#     last_queue_comment: {created_at, updated_at, html_url, body} | null }
# Output: { state, queue_active, merge_branch, merge_pr, merge_pr_source,
#           comment_after_head, head_sha, head_committed_at, last_queue_comment }

# Marker on Trunk's un-submitted control comment. Trunk edits this one comment in
# place as the PR moves through the queue, and the marker is gone once it has.
def CONTROL_MARKER: "<!-- Trunk Merge -->";

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
   | ($in.head_committed_at // "") as $pushed
   | if ($written | test("Z$")) and ($pushed | test("Z$"))
     then $written > $pushed
     else null
     end) as $comment_after_head
| ((($in.queue_active // false) or ($comment != null)) as $active
   | if ($active | not) then "no_queue"
     elif ($in.pr_merged // false) then "landed"
     elif ($refs | length) > 0 then "testing"
     elif $engaged then "blocked"
     else "not_enqueued"
     end) as $state
| {
    state: $state,
    queue_active: (($in.queue_active // false) or ($comment != null)),
    merge_branch: (($in.merge_branch // "") | if . == "" then null else . end),
    merge_pr: (($in.merge_pr_from_ref // null) // $pr_from_comment),
    merge_pr_source: (if ($in.merge_pr_from_ref // null) != null then "branch"
                      elif $pr_from_comment != null then "comment"
                      else null end),
    comment_after_head: $comment_after_head,
    head_sha: ($in.head_sha // null),
    head_committed_at: ($in.head_committed_at // null),
    last_queue_comment: (if $comment == null then null
                         else {created_at: $comment.created_at,
                               updated_at: $comment.updated_at,
                               url: $comment.html_url,
                               body: $comment.body}
                         end)
  }
