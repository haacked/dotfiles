# requeue-verdict.jq - Pure verdict for auto-re-enqueueing a dropped PR.
#
# Decides whether it is safe to post `/trunk merge` on a PR the Trunk merge
# queue dropped. Re-enqueueing restores an enqueue the developer already made;
# it must never first-enqueue, never override a human cancel, and never forfeit
# a waiting PR's submission. Every condition therefore fails closed, and every
# failed condition is collected into `reasons` (no short-circuit) so a report
# shows the whole picture. `requeue_ok` is true iff `reasons` is empty.
#
# False negatives are harmless (the human gets the report and the command); a
# false positive may forfeit a waiting PR's submission or override a human
# cancel, so it must never happen.
#
# Conditions:
#   1. queue.state is "blocked" - anything else means the queue moved on.
#   2. queue.blocked_reason is "dropped" - only a confirmed drop unlocks action.
#   3. queue.comment_after_head is true, or after_fix - a stale verdict may
#      describe an older head, and enqueueing a head the developer never
#      submitted crosses the first-enqueue line. after_fix waives this for a
#      caller who verified the drop in-session, pushed a fix, and watched the
#      PR's own CI go green; the eviction comment then legitimately predates
#      the head.
#   4. pr_state is "OPEN" - a closed-unmerged PR still reads blocked, and
#      re-enqueueing it would express reopen intent.
#   5. The merge PR, when identified, is verifiably Trunk's (head branch
#      `trunk-merge/pr-<N>/`, author `app/trunk-io`) and no longer open - an
#      open merge PR means the attempt may be live, e.g. mid-bisect. When no
#      merge PR is identified, only a timeout drop (dropped_marker
#      "removed_from_queue") passes: it leaves nothing to triage, whereas a
#      check-failure drop without an identifiable merge PR cannot be triaged.
#      The absent-merge-PR case only reports for a confirmed drop - on any
#      other blocked_reason, condition 2 already says what matters.
#   6. queue.enqueue_comments_since_head <= max_auto_requeues. The count
#      includes the developer's own original comment-enqueue when there was
#      one, so a max of 2 yields ~2 autos for a comment-enqueued head and ~3
#      for a checkbox-enqueued one - an approximation; the caller's in-session
#      counter is the tight bound. A null count is unreadable and denies.
#
# Input (stdin), one object:
#   { queue: <ci-queue-status.sh output>, pr_number, pr_state,
#     merge_pr_head, merge_pr_author, merge_pr_state,
#     max_auto_requeues, after_fix }
# Output: { requeue_ok, reasons, state, blocked_reason, dropped_marker,
#           comment_after_head, merge_pr, merge_pr_verified,
#           enqueue_comment_count, max_auto_requeues, head_sha,
#           head_committed_at }

. as $in
| ($in.queue // {}) as $q
| (($q.merge_pr // null) != null) as $has_merge_pr
| (if $has_merge_pr
   then (($in.merge_pr_head // "")
         | startswith("trunk-merge/pr-" + ($in.pr_number | tostring) + "/"))
        and (($in.merge_pr_author // "") == "app/trunk-io")
   else false
   end) as $merge_pr_verified
| ([]
   + (if ($q.state // "") == "blocked" then []
      else ["state is \($q.state // "unreadable"), not blocked"] end)
   + (if ($q.blocked_reason // "") == "dropped" then []
      else ["blocked_reason is \($q.blocked_reason // "null"); only dropped unlocks requeue"] end)
   + (if ($q.comment_after_head == true) or ($in.after_fix // false) then []
      else ["queue status may predate the current head (comment_after_head: \($q.comment_after_head))"] end)
   + (if ($in.pr_state // "") == "OPEN" then []
      else ["PR state is \($in.pr_state // "unknown"), not OPEN"] end)
   + (if $has_merge_pr then
        (if ($merge_pr_verified | not)
         then ["merge PR #\($q.merge_pr) is not verifiably Trunk's (head or author mismatch)"]
         elif ($in.merge_pr_state // "") == ""
         then ["merge PR #\($q.merge_pr) state unreadable"]
         elif $in.merge_pr_state == "OPEN"
         then ["merge PR #\($q.merge_pr) is still open - the queue attempt may be live"]
         else [] end)
      elif ($q.blocked_reason // "") != "dropped" then []
      elif ($q.dropped_marker // "") == "removed_from_queue" then []
      else ["no merge PR identified to triage a check-failure drop"] end)
   + (if ($q.enqueue_comments_since_head | type) != "number"
      then ["enqueue comment count unreadable"]
      elif $q.enqueue_comments_since_head > ($in.max_auto_requeues // 0)
      then ["auto-requeue budget exhausted (\($q.enqueue_comments_since_head) /trunk merge comment(s) since head, max \($in.max_auto_requeues // 0))"]
      else [] end)
  ) as $reasons
| {
    requeue_ok: ($reasons | length == 0),
    reasons: $reasons,
    state: ($q.state // null),
    blocked_reason: ($q.blocked_reason // null),
    dropped_marker: ($q.dropped_marker // null),
    comment_after_head: ($q.comment_after_head // null),
    merge_pr: ($q.merge_pr // null),
    merge_pr_verified: $merge_pr_verified,
    enqueue_comment_count: ($q.enqueue_comments_since_head // null),
    max_auto_requeues: ($in.max_auto_requeues // null),
    head_sha: ($q.head_sha // null),
    head_committed_at: ($q.head_committed_at // null)
  }
