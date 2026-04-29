#!/bin/bash
# Tests for the discovery jq filter loaded by review-all-prs.sh.
#
# Usage: test-review-filter.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

filter_prs() {
    local user="$1"
    local include_reviewed="$2"
    local input="$3"
    echo "$input" | jq \
        --arg user "$user" \
        --argjson include_reviewed "$include_reviewed" \
        -f "$SCRIPT_DIR/review-filter.jq"
}

make_review() {
    # login state submittedAt(or empty for null) createdAt
    jq -n --arg l "$1" --arg s "$2" --arg sub "$3" --arg cre "$4" '{
        author: {login: $l},
        state: $s,
        submittedAt: (if $sub == "" then null else $sub end),
        createdAt: $cre
    }'
}

make_pr() {
    local number="$1"
    local last_commit_at="$2"
    local reviews_json="$3"
    jq -n --argjson n "$number" --arg c "$last_commit_at" --argjson r "$reviews_json" '{
        number: $n,
        title: ("PR " + ($n | tostring)),
        url: ("https://github.com/org/repo/pull/" + ($n | tostring)),
        repository: {nameWithOwner: "org/repo"},
        author: {login: "author"},
        updatedAt: "2024-01-15T10:00:00Z",
        reviews: {nodes: $r},
        commits: {nodes: [{commit: {committedDate: $c}}]}
    }'
}

# ── Test data ─────────────────────────────────────────────────────────────

USER="me"
T08="2024-01-15T08:00:00Z"
T09="2024-01-15T09:00:00Z"
T0930="2024-01-15T09:30:00Z"
T10="2024-01-15T10:00:00Z"
T11="2024-01-15T11:00:00Z"

# 1: never reviewed
pr_unreviewed=$(make_pr 1 "$T10" "[]")

# 2: APPROVED with new commits since review (re-review candidate)
pr_approved_new=$(make_pr 2 "$T11" "[$(make_review me APPROVED "$T10" "$T10")]")

# 3: APPROVED with no new commits since review (skip)
pr_approved_stale=$(make_pr 3 "$T09" "[$(make_review me APPROVED "$T10" "$T10")]")

# 4: PENDING (submittedAt null), commits after createdAt (refresh draft)
pr_pending_new=$(make_pr 4 "$T11" "[$(make_review me PENDING "" "$T10")]")

# 5: PENDING with no new commits since createdAt (skip)
pr_pending_stale=$(make_pr 5 "$T09" "[$(make_review me PENDING "" "$T10")]")

# 6: COMMENTED with no new commits — new filter drops this (old filter kept it)
pr_commented_stale=$(make_pr 6 "$T09" "[$(make_review me COMMENTED "$T10" "$T10")]")

# 7: only reviewed by another user — treated as unreviewed by me
pr_other_review=$(make_pr 7 "$T09" "[$(make_review other APPROVED "$T10" "$T10")]")

# 8: multiple reviews by user; "last" wins (older COMMENTED, newer APPROVED, no new commits → skip)
pr_multi_review=$(make_pr 8 "$T0930" \
    "[$(make_review me COMMENTED "$T08" "$T08"),$(make_review me APPROVED "$T10" "$T10")]")

input=$(jq -s '.' <<EOF
$pr_unreviewed
$pr_approved_new
$pr_approved_stale
$pr_pending_new
$pr_pending_stale
$pr_commented_stale
$pr_other_review
$pr_multi_review
EOF
)

# ── Test: default filter keeps unreviewed and PRs with new commits ────────

result=$(filter_prs "$USER" "false" "$input")
numbers=$(echo "$result" | jq -c '[.[].number] | sort')
assert "default filter keeps {1, 2, 4, 7}: unreviewed, approved-with-new-commits, pending-with-new-commits, other-reviewer" \
    test "$numbers" = "[1,2,4,7]"

# ── Test: --include-reviewed keeps every PR ───────────────────────────────

result=$(filter_prs "$USER" "true" "$input")
count=$(echo "$result" | jq 'length')
assert "include_reviewed=true keeps all 8 PRs" test "$count" -eq 8

# ── Test: PENDING fallback to createdAt admits draft refresh ──────────────

result=$(filter_prs "$USER" "false" "[$pr_pending_new]")
state=$(echo "$result" | jq -r '.[0].user_review_state')
assert "PENDING with new commits is kept via createdAt fallback" test "$state" = "PENDING"

# ── Test: PENDING with no new commits drops ───────────────────────────────

result=$(filter_prs "$USER" "false" "[$pr_pending_stale]")
count=$(echo "$result" | jq 'length')
assert "PENDING with no new commits is dropped" test "$count" -eq 0

# ── Test: COMMENTED with no new commits drops (new filter behavior) ──────

result=$(filter_prs "$USER" "false" "[$pr_commented_stale]")
count=$(echo "$result" | jq 'length')
assert "COMMENTED with no new commits is dropped" test "$count" -eq 0

# ── Test: equal timestamps drop (commit must be strictly newer) ──────────

pr_equal=$(make_pr 9 "$T10" "[$(make_review me APPROVED "$T10" "$T10")]")
result=$(filter_prs "$USER" "false" "[$pr_equal]")
count=$(echo "$result" | jq 'length')
assert "equal commit and review timestamps drop the PR" test "$count" -eq 0

# ── Test: latest review by user wins (multiple reviews) ──────────────────

result=$(filter_prs "$USER" "false" "[$pr_multi_review]")
count=$(echo "$result" | jq 'length')
assert "multiple reviews: APPROVED-latest with no new commits drops" test "$count" -eq 0

# ── Test: empty input ─────────────────────────────────────────────────────

result=$(filter_prs "$USER" "false" "[]")
count=$(echo "$result" | jq 'length')
assert "empty input returns empty output" test "$count" -eq 0

# ── Test: user_review_state is null for unreviewed PR ─────────────────────

result=$(filter_prs "$USER" "false" "[$pr_unreviewed]")
state=$(echo "$result" | jq '.[0].user_review_state')
assert "unreviewed PR has null user_review_state in output" test "$state" = "null"

# ── Results ───────────────────────────────────────────────────────────────

print_results
