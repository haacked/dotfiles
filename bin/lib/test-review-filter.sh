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
    local team_members="${4:-[]}"
    echo "$input" | jq \
        --arg user "$user" \
        --argjson include_reviewed "$include_reviewed" \
        --argjson team_members "$team_members" \
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
    # number last_commit_at reviews_json [author] [title] [updated_at]
    local number="$1"
    local last_commit_at="$2"
    local reviews_json="$3"
    local author="${4:-author}"
    local title="${5:-PR $number}"
    local updated_at="${6:-2024-01-15T10:00:00Z}"
    jq -n --argjson n "$number" --arg c "$last_commit_at" --argjson r "$reviews_json" \
        --arg a "$author" --arg t "$title" --arg u "$updated_at" '{
        number: $n,
        title: $t,
        url: ("https://github.com/org/repo/pull/" + ($n | tostring)),
        repository: {nameWithOwner: "org/repo"},
        author: {login: $a},
        updatedAt: $u,
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

# ── Priority tests ────────────────────────────────────────────────────────

TEAM='["teammate"]'

pr_team=$(make_pr 10 "$T10" "[]" teammate "fix: something unrelated")
pr_flags_scope=$(make_pr 11 "$T10" "[]" stranger "feat(flags): add gating")
pr_feature_flags_scope=$(make_pr 12 "$T10" "[]" stranger "chore(feature-flags): cleanup")
pr_rest=$(make_pr 13 "$T10" "[]" stranger "fix(api): unrelated")
pr_flags_word_only=$(make_pr 14 "$T10" "[]" stranger "Add flags to the CLI")

priority_input=$(jq -s '.' <<EOF
$pr_rest
$pr_flags_scope
$pr_team
$pr_feature_flags_scope
$pr_flags_word_only
EOF
)

result=$(filter_prs "$USER" "false" "$priority_input" "$TEAM")

assert "team-authored PR gets priority 1" \
    test "$(echo "$result" | jq '.[] | select(.number == 10) | .priority')" = "1"
assert "feat(flags) title gets priority 2" \
    test "$(echo "$result" | jq '.[] | select(.number == 11) | .priority')" = "2"
assert "chore(feature-flags) title gets priority 2" \
    test "$(echo "$result" | jq '.[] | select(.number == 12) | .priority')" = "2"
assert "unrelated PR gets priority 3" \
    test "$(echo "$result" | jq '.[] | select(.number == 13) | .priority')" = "3"
assert "'flags' outside a conventional scope is not priority 2" \
    test "$(echo "$result" | jq '.[] | select(.number == 14) | .priority')" = "3"

ordered=$(echo "$result" | jq -c '[.[].priority]')
assert "output is sorted by priority ascending" test "$ordered" = "[1,2,2,3,3]"

# Within a tier, most recently updated comes first.
pr_old=$(make_pr 20 "$T10" "[]" stranger "fix(api): old" "2024-01-14T10:00:00Z")
pr_new=$(make_pr 21 "$T10" "[]" stranger "fix(api): new" "2024-01-15T10:00:00Z")
result=$(filter_prs "$USER" "false" "[$pr_old,$pr_new]")
first=$(echo "$result" | jq '.[0].number')
assert "within a tier, most recently updated sorts first" test "$first" = "21"

# Team membership beats a flags scope: priority is the author's tier.
pr_team_flags=$(make_pr 22 "$T10" "[]" teammate "feat(flags): from teammate")
result=$(filter_prs "$USER" "false" "[$pr_team_flags]" "$TEAM")
assert "team-authored flags PR is priority 1, not 2" \
    test "$(echo "$result" | jq '.[0].priority')" = "1"

# ── Results ───────────────────────────────────────────────────────────────

print_results
