#!/bin/bash
# Tests for ensure-diff3-markers.sh conflict marker rewriting.
#
# Each test creates a temporary git repository with a real failed merge, so the
# index carries genuine unmerged stages, runs the script, and compares the
# output and the working-tree file.
#
# The host gitconfig may set merge.conflictStyle, which would hide the rewrite
# cases, so every git invocation and the script run see empty global and system
# config.
#
# Usage: test-ensure-diff3-markers.sh

set -euo pipefail

export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_SYSTEM=/dev/null

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$SCRIPT_DIR/ensure-diff3-markers.sh"

passes=0
failures=0

# Leaves the repository mid-merge with "$1" (default conflict.txt) unmerged.
setup_repo() {
    local file="${1:-conflict.txt}"
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ensure-diff3.XXXXXX")
    git -C "$tmp" init -q
    git -C "$tmp" config user.name "Test User"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config commit.gpgsign false
    printf 'top\nbase line\nbottom\n' > "$tmp/$file"
    git -C "$tmp" add -- "$file"
    git -C "$tmp" commit -q -m "init"
    local base
    base=$(git -C "$tmp" branch --show-current)
    git -C "$tmp" checkout -q -b theirs
    printf 'top\ntheir line\nbottom\n' > "$tmp/$file"
    git -C "$tmp" commit -q -a -m "theirs"
    git -C "$tmp" checkout -q "$base"
    printf 'top\nour line\nbottom\n' > "$tmp/$file"
    git -C "$tmp" commit -q -a -m "ours"
    git -C "$tmp" merge -q theirs >/dev/null 2>&1 || true
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
        echo "  expected: $(printf '%s' "$expected" | cat -et)"
        echo "  actual:   $(printf '%s' "$actual" | cat -et)"
        failures=$((failures + 1))
    fi
}

assert_base_section() {
    local description="$1"
    local file="$2"
    assert_output "$description" "1" "$(grep -c '^|||||||' "$file" || true)"
}

# --- Styles that leave git without a base section ---

assert_rewrites_under_style() {
    local style="$1"
    local file="${2:-conflict.txt}"
    local label="${style:-unset} style"
    local repo
    repo=$(setup_repo "$file")
    if [[ -n "$style" ]]; then
        git -C "$repo" config merge.conflictStyle "$style"
    fi
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "$label reports the rewrite" "$(printf 'rewrote\t%s' "$file")" "$output"
    assert_base_section "$label adds a base section" "$repo/$file"
    rm -rf "$repo"
}

test_styles_without_base_section() {
    assert_rewrites_under_style ""
    assert_rewrites_under_style "merge"
}

# --- Styles that already give git a base section ---

assert_skips_under_style() {
    local style="$1"
    local repo
    repo=$(setup_repo)
    git -C "$repo" config merge.conflictStyle "$style"
    local before
    before=$(cat "$repo/conflict.txt")
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "$style style prints nothing" "" "$output"
    assert_output "$style style leaves the file untouched" "$before" "$(cat "$repo/conflict.txt")"
    rm -rf "$repo"
}

test_styles_with_base_section() {
    assert_skips_under_style "diff3"
    assert_skips_under_style "zdiff3"
}

# --- Unmerged index entry with a resolved working tree (rerere) ---

test_resolved_working_tree_survives() {
    local repo
    repo=$(setup_repo)
    local resolved=$'top\nour line\ntheir line\nbottom'
    printf '%s\n' "$resolved" > "$repo/conflict.txt"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "resolved working tree prints nothing" "" "$output"
    assert_output "resolved content survives" "$resolved" "$(cat "$repo/conflict.txt")"
    rm -rf "$repo"
}

# --- Working tree already carries a base section ---

test_existing_base_section_skipped() {
    local repo
    repo=$(setup_repo)
    {
        echo "top"
        echo "<<<<<<< HEAD"
        echo "our line"
        echo "||||||| merged common ancestors"
        echo "base line"
        echo "======="
        echo "their line"
        echo ">>>>>>> theirs"
        echo "bottom"
    } > "$repo/conflict.txt"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "existing base section prints nothing" "" "$output"
    rm -rf "$repo"
}

# --- Add/add conflict, where the base side is empty ---

test_add_add_conflict() {
    local repo
    repo=$(mktemp -d "${TMPDIR:-/tmp}/ensure-diff3-addadd.XXXXXX")
    git -C "$repo" init -q
    git -C "$repo" config user.name "Test User"
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config commit.gpgsign false
    git -C "$repo" commit -q --allow-empty -m "init"
    local base
    base=$(git -C "$repo" branch --show-current)
    git -C "$repo" checkout -q -b theirs
    printf 'their line\n' > "$repo/added.txt"
    git -C "$repo" add -- added.txt
    git -C "$repo" commit -q -m "theirs"
    git -C "$repo" checkout -q "$base"
    printf 'our line\n' > "$repo/added.txt"
    git -C "$repo" add -- added.txt
    git -C "$repo" commit -q -m "ours"
    git -C "$repo" merge -q theirs >/dev/null 2>&1 || true
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "add/add reports the rewrite" "$(printf 'rewrote\tadded.txt')" "$output"
    assert_base_section "add/add adds an empty base section" "$repo/added.txt"
    rm -rf "$repo"
}

# --- A gitattributes merge driver overrides the diff3 style ---

test_merge_driver_output_not_reported() {
    local repo
    repo=$(setup_repo)
    git -C "$repo" config merge.fake.name "fake"
    git -C "$repo" config merge.fake.driver \
        "printf '<<<<<<< ours\nA\n=======\nB\n>>>>>>> theirs\n' > %A; exit 1"
    echo 'conflict.txt merge=fake' > "$repo/.gitattributes"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "driver output without a base section is not reported" "" "$output"
    rm -rf "$repo"
}

# --- Filename containing a space ---

test_filename_with_space() {
    assert_rewrites_under_style "" "with space.txt"
}

# --- Outside a git repository ---

test_outside_repository() {
    local dir
    dir=$(mktemp -d "${TMPDIR:-/tmp}/ensure-diff3-bare.XXXXXX")
    local status=0
    (cd "$dir" && GIT_CEILING_DIRECTORIES="$dir" bash "$SCRIPT" >/dev/null 2>&1) || status=$?
    assert_output "outside a repository exits 1" "1" "$status"
    rm -rf "$dir"
}

# --- Run all tests ---

test_styles_without_base_section
test_styles_with_base_section
test_resolved_working_tree_survives
test_existing_base_section_skipped
test_add_add_conflict
test_merge_driver_output_not_reported
test_filename_with_space
test_outside_repository

# --- Summary ---

echo ""
echo "Results: $passes passed, $failures failed"
if [[ "$failures" -gt 0 ]]; then
    exit 1
fi
