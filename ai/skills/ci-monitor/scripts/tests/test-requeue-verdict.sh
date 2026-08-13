#!/usr/bin/env bash
# Tests for requeue-verdict.jq, the pure auto-re-enqueue verdict.
#
# Feeds fixtures straight into the jq decision program and asserts on
# `requeue_ok`. The property under test is "false negatives are safe": every
# uncertain, stale, or contradictory input must yield requeue_ok:false; only a
# confirmed, current, budgeted drop may yield requeue_ok:true. A false positive
# posts a `/trunk merge` that may forfeit a waiting PR's submission or override
# a human cancel, so it must never happen.
#
# Usage: test-requeue-verdict.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECISION_JQ="${SCRIPT_DIR}/../helpers/requeue-verdict.jq"

passes=0
failures=0

# input '<field overrides, jq object syntax>' -> full verdict input,
# deep-merged over a happy-path base: a confirmed check-failure drop, fresh
# comment, open PR, verified closed merge PR, budget 1 of 2. The override is
# evaluated as a jq expression so fixtures can use bare keys and null.
input() {
    jq -n '{
        queue: {
            state: "blocked", blocked_reason: "dropped",
            dropped_marker: "check_failed", comment_after_head: true,
            merge_pr: 790, enqueue_comments_since_head: 1,
            head_sha: "headsha",
            head_committed_at: "2026-08-03T12:00:00Z"
        },
        pr_number: "789", pr_state: "OPEN",
        merge_pr_head: "trunk-merge/pr-789/uuid",
        merge_pr_author: "app/trunk-io", merge_pr_state: "CLOSED",
        max_auto_requeues: 2, after_fix: false
    } * ('"$1"')'
}

assert_requeue() {
    local description="$1" over="$2" expected="$3"
    local actual
    actual=$(input "${over}" | jq -f "${DECISION_JQ}" | jq -r '.requeue_ok')
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  expected requeue_ok=${expected}, got requeue_ok=${actual}"
        echo "  reasons: $(input "${over}" | jq -f "${DECISION_JQ}" | jq -c '.reasons')"
        failures=$((failures + 1))
    fi
}

# assert_reason '<desc>' '<over>' '<substring>' [true|false]
# -> asserts whether some reason mentions the substring (default: it does)
assert_reason() {
    local description="$1" over="$2" substring="$3" expected="${4:-true}"
    local matched
    matched=$(input "${over}" | jq -f "${DECISION_JQ}" \
        | jq -r --arg s "${substring}" '[.reasons[] | contains($s)] | any')
    if [[ "${matched}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  expected a '${substring}' reason match of ${expected}, got ${matched}"
        echo "  reasons: $(input "${over}" | jq -f "${DECISION_JQ}" | jq -c '.reasons')"
        failures=$((failures + 1))
    fi
}

# assert_verified '<desc>' '<over>' <true|false> -> asserts merge_pr_verified,
# which SKILL.md 7c reads to decide whether the merge PR number can be trusted.
assert_verified() {
    local description="$1" over="$2" expected="$3"
    local actual
    actual=$(input "${over}" | jq -f "${DECISION_JQ}" | jq -r '.merge_pr_verified')
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  expected merge_pr_verified=${expected}, got merge_pr_verified=${actual}"
        failures=$((failures + 1))
    fi
}

# 1. The happy path: confirmed fresh drop, open PR, verified closed merge PR,
#    budget available.
assert_requeue "confirmed current drop -> true" '{}' "true"

# 2. Only "dropped" unlocks action.
assert_requeue "waiting -> false" \
    '{queue: {blocked_reason: "waiting", dropped_marker: null}}' "false"
assert_requeue "unknown -> false" \
    '{queue: {blocked_reason: "unknown", dropped_marker: null}}' "false"

# 3. Only "blocked" is actionable; anything else means the queue moved on.
assert_requeue "testing -> false" \
    '{queue: {state: "testing"}}' "false"
assert_requeue "not_enqueued -> false" \
    '{queue: {state: "not_enqueued", blocked_reason: null, dropped_marker: null}}' "false"

# 4. Freshness: a stale or uncomparable verdict may describe an older head.
#    Only after_fix (in-session verified drop, fix pushed, PR green) waives it.
assert_requeue "stale comment -> false" \
    '{queue: {comment_after_head: false}}' "false"
assert_requeue "stale comment + after_fix -> true" \
    '{queue: {comment_after_head: false}, after_fix: true}' "true"
# after_fix waives only freshness: it must never rescue a PR that is waiting
# to get in or still being tested.
assert_requeue "after_fix does not rescue waiting" \
    '{queue: {blocked_reason: "waiting", dropped_marker: null, comment_after_head: false}, after_fix: true}' "false"
assert_requeue "after_fix does not rescue testing" \
    '{queue: {state: "testing", blocked_reason: null, dropped_marker: null, comment_after_head: false}, after_fix: true}' "false"
assert_requeue "uncomparable freshness -> false" \
    '{queue: {comment_after_head: null}}' "false"

# 5. A closed-unmerged PR still reads blocked; requeueing would express reopen
#    intent.
assert_requeue "closed PR -> false" \
    '{pr_state: "CLOSED"}' "false"

# 6. An open merge PR means the attempt may be live (mid-bisect).
assert_requeue "merge PR still open -> false" \
    '{merge_pr_state: "OPEN"}' "false"

# 7. Merge PR identity: wrong PR's branch or a human author fails verification.
assert_requeue "merge branch for another PR -> false" \
    '{merge_pr_head: "trunk-merge/pr-99999/uuid"}' "false"
assert_requeue "human-authored merge PR -> false" \
    '{merge_pr_author: "haacked"}' "false"
assert_verified "happy path verifies the merge PR" '{}' "true"
assert_verified "merge branch for another PR fails verification" \
    '{merge_pr_head: "trunk-merge/pr-99999/uuid"}' "false"
assert_verified "human-authored merge PR fails verification" \
    '{merge_pr_author: "haacked"}' "false"

# 8. No merge PR identified: a timeout drop leaves nothing to triage, so it
#    passes; a check-failure drop cannot be triaged, so it fails.
assert_requeue "no merge PR, timeout drop -> true" \
    '{queue: {merge_pr: null, dropped_marker: "removed_from_queue"},
      merge_pr_head: null, merge_pr_author: null, merge_pr_state: null}' "true"
assert_requeue "no merge PR, check-failure drop -> false" \
    '{queue: {merge_pr: null}, merge_pr_head: null, merge_pr_author: null, merge_pr_state: null}' "false"

# 9. Budget: the count includes the original comment-enqueue, bounded at max.
assert_requeue "budget at limit -> true" \
    '{queue: {enqueue_comments_since_head: 2}}' "true"
assert_requeue "budget exhausted -> false" \
    '{queue: {enqueue_comments_since_head: 3}}' "false"
assert_requeue "unreadable count -> false" \
    '{queue: {enqueue_comments_since_head: null}}' "false"

# 10. Every failed condition is reported, not just the first.
multi='{queue: {state: "testing", enqueue_comments_since_head: 5}, pr_state: "CLOSED"}'
assert_reason "multi-failure reports state" "${multi}" "not blocked"
assert_reason "multi-failure reports PR state" "${multi}" "not OPEN"
assert_reason "multi-failure reports budget" "${multi}" "budget exhausted"

# 11. The absent-merge-PR reason only means something for a confirmed drop; on
#     any other verdict it would be noise next to the reason that matters.
assert_reason "landed PR reports no absent-merge-PR reason" \
    '{queue: {state: "landed", blocked_reason: null, dropped_marker: null, merge_pr: null},
      merge_pr_head: null, merge_pr_author: null, merge_pr_state: null}' \
    "no merge PR" "false"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
