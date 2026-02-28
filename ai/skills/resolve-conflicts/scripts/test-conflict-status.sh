#!/bin/bash
# Tests for conflict-status.sh context detection.
#
# Each test creates a temporary git repository, simulates git internal state
# by placing the appropriate files and directories under .git/, runs the
# script, and compares the output.
#
# Usage: test-conflict-status.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/conflict-status.sh"

passes=0
failures=0

setup_repo() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/conflict-status.XXXXXX")
    git -C "$tmp" init -q
    git -C "$tmp" config user.name "Test User"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" commit --allow-empty -m "init" -q
    echo "$tmp"
}

assert_output() {
    local description="$1"
    local expected="$2"
    local actual="$3"
    if [[ "$actual" == "$expected" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        echo "  expected: $(printf '%s' "$expected" | cat -vET)"
        echo "  actual:   $(printf '%s' "$actual" | cat -vET)"
        failures=$((failures + 1))
    fi
}

# --- No operation in progress ---

test_none() {
    local repo
    repo=$(setup_repo)
    local branch
    branch=$(git -C "$repo" branch --show-current)
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "no operation reports none" "$(printf 'none\t\t%s' "$branch")" "$output"
    rm -rf "$repo"
}

# --- Merge ---

test_merge() {
    local repo
    repo=$(setup_repo)
    touch "$repo/.git/MERGE_HEAD"
    local branch
    branch=$(git -C "$repo" branch --show-current)
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "merge detected" "$(printf 'merge\t\t%s' "$branch")" "$output"
    rm -rf "$repo"
}

# --- Cherry-pick ---

test_cherry_pick() {
    local repo
    repo=$(setup_repo)
    touch "$repo/.git/CHERRY_PICK_HEAD"
    local branch
    branch=$(git -C "$repo" branch --show-current)
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "cherry-pick detected" "$(printf 'cherry-pick\t\t%s' "$branch")" "$output"
    rm -rf "$repo"
}

# --- Revert ---

test_revert() {
    local repo
    repo=$(setup_repo)
    touch "$repo/.git/REVERT_HEAD"
    local branch
    branch=$(git -C "$repo" branch --show-current)
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "revert detected" "$(printf 'revert\t\t%s' "$branch")" "$output"
    rm -rf "$repo"
}

# --- Rebase (interactive) via rebase-merge with progress ---

test_rebase_merge_with_progress() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "3" > "$repo/.git/rebase-merge/msgnum"
    echo "12" > "$repo/.git/rebase-merge/end"
    echo "refs/heads/feature-branch" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "rebase-merge with progress" "$(printf 'rebase\t3/12\tfeature-branch')" "$output"
    rm -rf "$repo"
}

# --- Rebase (apply-based) via rebase-apply with progress ---

test_rebase_apply_with_progress() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-apply"
    echo "5" > "$repo/.git/rebase-apply/next"
    echo "8" > "$repo/.git/rebase-apply/last"
    echo "refs/heads/my-branch" > "$repo/.git/rebase-apply/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "rebase-apply with progress" "$(printf 'rebase\t5/8\tmy-branch')" "$output"
    rm -rf "$repo"
}

# --- Rebase with missing progress files ---

test_rebase_no_progress() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "refs/heads/some-branch" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "rebase without progress" "$(printf 'rebase\t\tsome-branch')" "$output"
    rm -rf "$repo"
}

# --- Rebase with partial progress (only current, no total) ---

test_rebase_partial_progress() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "3" > "$repo/.git/rebase-merge/msgnum"
    echo "refs/heads/partial" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "rebase with only current (no total) omits progress" \
        "$(printf 'rebase\t\tpartial')" "$output"
    rm -rf "$repo"
}

# --- head-name strips refs/heads/ prefix ---

test_head_name_prefix_stripping() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "1" > "$repo/.git/rebase-merge/msgnum"
    echo "1" > "$repo/.git/rebase-merge/end"
    echo "refs/heads/haacked/my-feature" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "head-name strips refs/heads/ prefix" \
        "$(printf 'rebase\t1/1\thaacked/my-feature')" "$output"
    rm -rf "$repo"
}

# --- head-name without refs/heads/ prefix passes through unchanged ---

test_head_name_no_prefix() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "1" > "$repo/.git/rebase-merge/msgnum"
    echo "1" > "$repo/.git/rebase-merge/end"
    echo "detached-ref" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "head-name without prefix passes through" \
        "$(printf 'rebase\t1/1\tdetached-ref')" "$output"
    rm -rf "$repo"
}

# --- Rebase takes priority over merge (edge case: both present) ---

test_rebase_priority_over_merge() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "2" > "$repo/.git/rebase-merge/msgnum"
    echo "5" > "$repo/.git/rebase-merge/end"
    echo "refs/heads/priority-test" > "$repo/.git/rebase-merge/head-name"
    touch "$repo/.git/MERGE_HEAD"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "rebase takes priority over merge" \
        "$(printf 'rebase\t2/5\tpriority-test')" "$output"
    rm -rf "$repo"
}

# --- msgnum preferred over next in rebase-merge ---

test_msgnum_preferred_over_next() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "7" > "$repo/.git/rebase-merge/msgnum"
    echo "99" > "$repo/.git/rebase-merge/next"
    echo "10" > "$repo/.git/rebase-merge/end"
    echo "refs/heads/fallback-test" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "msgnum preferred over next" \
        "$(printf 'rebase\t7/10\tfallback-test')" "$output"
    rm -rf "$repo"
}

# --- end preferred over last in rebase-merge ---

test_end_preferred_over_last() {
    local repo
    repo=$(setup_repo)
    mkdir -p "$repo/.git/rebase-merge"
    echo "1" > "$repo/.git/rebase-merge/msgnum"
    echo "10" > "$repo/.git/rebase-merge/end"
    echo "99" > "$repo/.git/rebase-merge/last"
    echo "refs/heads/fallback-test" > "$repo/.git/rebase-merge/head-name"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "end preferred over last" \
        "$(printf 'rebase\t1/10\tfallback-test')" "$output"
    rm -rf "$repo"
}

# --- Run all tests ---

test_none
test_merge
test_cherry_pick
test_revert
test_rebase_merge_with_progress
test_rebase_apply_with_progress
test_rebase_no_progress
test_rebase_partial_progress
test_head_name_prefix_stripping
test_head_name_no_prefix
test_rebase_priority_over_merge
test_msgnum_preferred_over_next
test_end_preferred_over_last

# --- Summary ---

echo ""
echo "Results: $passes passed, $failures failed"
if [[ "$failures" -gt 0 ]]; then
    exit 1
fi
