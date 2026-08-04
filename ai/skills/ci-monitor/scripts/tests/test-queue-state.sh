#!/usr/bin/env bash
# Tests for queue-state.jq, the Trunk merge-queue verdict.
#
# The verdict decides whether a green PR is actually done (nothing merges without
# passing the queue) and whether pushing to the branch is safe - a push silently
# drops a PR out of the queue. Both hinge on telling "testing" apart from
# "blocked" and "not_enqueued" using a machine marker and a branch, never the
# bot's prose.
#
# Usage: test-queue-state.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_JQ="${SCRIPT_DIR}/../helpers/queue-state.jq"

passes=0
failures=0

# input '<field overrides json>' -> full verdict input with sane defaults
input() {
    jq -n --argjson over "$1" '{
        owner: "PostHog", repo: "posthog",
        pr_merged: false, head_sha: "headsha",
        head_committed_at: "2026-08-03T12:00:00Z",
        refs_for_pr: [], queue_active: true, merge_branch: "",
        merge_pr_from_ref: null, last_queue_comment: null
    } + $over'
}

# field accepts a dotted path so nested output can be asserted too.
assert_field() {
    local description="$1" over="$2" field="$3" expected="$4"
    local actual
    actual=$(input "${over}" | jq -f "${STATE_JQ}" \
        | jq -r --arg f "${field}" 'getpath($f | split(".")) | tostring')
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  ${field}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

# comment '<body>' [<updated_at>] -> a Trunk status comment object
comment() {
    jq -c -n --arg b "$1" --arg u "${2:-2026-08-03T13:00:00Z}" \
        '{created_at: "2026-08-03T11:00:00Z", updated_at: $u,
          html_url: "https://github.com/PostHog/posthog/pull/1#issuecomment-1", body: $b}'
}

CONTROL='<!-- Trunk Merge -->
Merging to `master` in this repository is managed by Trunk.
- [ ] To merge this pull request, check the box to the left or comment `/trunk merge` below.'
TESTING='🧪 Running tests on this pull request (testing on PR [#77010](https://www.github.com/PostHog/posthog/pull/77010)) - [details](https://app.trunk.io/x).'
FAILED='⚠️ The required check [`Visual regression tests pass`](https://github.com/PostHog/posthog/actions/runs/1/job/2) (Failure) has failed. PR [#77007](https://www.github.com/PostHog/posthog/pull/77007)'

# ── States ───────────────────────────────────────────────────────────────────

# No Trunk anywhere: the queue rules must not apply to ordinary repos.
assert_field "no refs and no bot comment -> no_queue" \
    '{"queue_active": false}' state "no_queue"

# The control comment is Trunk watching, not Trunk testing. Treating it as
# engagement would block pushes on every PR in the repo.
assert_field "control comment -> not_enqueued" \
    "$(jq -n --argjson c "$(comment "${CONTROL}")" '{last_queue_comment: $c}')" \
    state "not_enqueued"

# A Trunk comment proves the queue is in use even when no trunk-merge branch
# exists anywhere. The repo-wide probe only sees branches, and Trunk deletes each
# one when its attempt ends, so a quiet queue reports queue_active false; without
# the comment fallback the whole repo would read as no_queue and every gate keyed
# on it would open.
assert_field "idle queue, control comment -> not_enqueued" \
    "$(jq -n --argjson c "$(comment "${CONTROL}")" '{queue_active: false, last_queue_comment: $c}')" \
    state "not_enqueued"

assert_field "idle queue, engaged comment -> blocked" \
    "$(jq -n --argjson c "$(comment "${FAILED}")" '{queue_active: false, last_queue_comment: $c}')" \
    state "blocked"

# A trunk-merge branch is the queue actively testing this PR.
assert_field "trunk-merge branch -> testing" \
    '{"refs_for_pr": ["refs/heads/trunk-merge/pr-77004/uuid"]}' state "testing"

# The wrapper picks which branch is live (highest merge PR number wins) and hands
# it over; the verdict reports that choice rather than re-deriving it from the
# ref list, so the branch always matches the merge PR the caller is told to poll.
assert_field "reports the branch the wrapper selected" \
    '{"refs_for_pr": ["refs/heads/trunk-merge/pr-77004/attempt-a", "refs/heads/trunk-merge/pr-77004/attempt-b"],
      "merge_branch": "trunk-merge/pr-77004/attempt-b", "merge_pr_from_ref": 77011}' \
    merge_branch "trunk-merge/pr-77004/attempt-b"

# Merged wins over a branch ref that has not been cleaned up yet.
assert_field "merged -> landed even with a lingering ref" \
    '{"pr_merged": true, "refs_for_pr": ["refs/heads/trunk-merge/pr-77004/uuid"]}' \
    state "landed"

# Engaged, no branch, unmerged: failed out, cancelled, or between attempts.
assert_field "status comment with no branch -> blocked" \
    "$(jq -n --argjson c "$(comment "${FAILED}")" '{last_queue_comment: $c}')" \
    state "blocked"

# ── Merge PR resolution ──────────────────────────────────────────────────────

# The two sources carry different numbers so the value proves which one won, not
# just the label. SKILL.md skips the merge-PR verification when the source reads
# "branch", so a source that lied would send it to fetch a comment-scraped number
# unchecked.
assert_field "branch-derived merge PR wins" \
    "$(jq -n --argjson c "$(comment "${TESTING}")" \
        '{merge_pr_from_ref: 77011, refs_for_pr: ["refs/heads/trunk-merge/pr-77004/uuid"], last_queue_comment: $c}')" \
    merge_pr_source "branch"

assert_field "branch-derived merge PR wins the value too" \
    "$(jq -n --argjson c "$(comment "${TESTING}")" \
        '{merge_pr_from_ref: 77011, refs_for_pr: ["refs/heads/trunk-merge/pr-77004/uuid"], last_queue_comment: $c}')" \
    merge_pr "77011"

assert_field "comment-derived merge PR is labelled comment" \
    "$(jq -n --argjson c "$(comment "${FAILED}")" '{last_queue_comment: $c}')" \
    merge_pr_source "comment"

assert_field "falls back to the PR Trunk linked once the branch is gone" \
    "$(jq -n --argjson c "$(comment "${FAILED}")" '{last_queue_comment: $c}')" \
    merge_pr "77007"

# A link to another repo must never be followed: the caller fetches whatever
# number comes back, so cross-repo links are dropped rather than resolved.
assert_field "ignores a merge PR link pointing at another repo" \
    "$(jq -n --argjson c "$(comment "see https://github.com/attacker/evil/pull/9")" \
        '{last_queue_comment: $c}')" \
    merge_pr "null"

# ── Freshness of the verdict ─────────────────────────────────────────────────

assert_field "status written after the push is current" \
    "$(jq -n --argjson c "$(comment "${FAILED}" "2026-08-03T13:00:00Z")" '{last_queue_comment: $c}')" \
    comment_after_head "true"

assert_field "status predating the push is stale" \
    "$(jq -n --argjson c "$(comment "${FAILED}" "2026-08-03T11:30:00Z")" '{last_queue_comment: $c}')" \
    comment_after_head "false"

# An unparseable timestamp reports unknown rather than guessing a comparison.
assert_field "non-UTC timestamp -> unknown freshness" \
    "$(jq -n --argjson c "$(comment "${FAILED}" "2026-08-03T06:30:00-07:00")" '{last_queue_comment: $c}')" \
    comment_after_head "null"

# ── Blocked-report payload ───────────────────────────────────────────────────
# A blocked PR's whole report is Trunk's comment: the body as the reason and the
# url as the permalink. If either goes missing the report is empty and nothing
# else fails, so both are pinned. The rename from html_url is deliberate.

assert_field "blocked report keeps the comment permalink" \
    "$(jq -n --argjson c "$(comment "${FAILED}")" '{last_queue_comment: $c}')" \
    last_queue_comment.url "https://github.com/PostHog/posthog/pull/1#issuecomment-1"

assert_field "blocked report keeps the comment body" \
    "$(jq -n --argjson c "$(comment "${FAILED}")" '{last_queue_comment: $c}')" \
    last_queue_comment.body "${FAILED}"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
