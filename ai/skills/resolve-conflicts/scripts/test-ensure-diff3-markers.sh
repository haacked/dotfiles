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

# Prints the path of an empty repository whose temp name starts with "$1".
init_repo() {
    local tmp
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/$1.XXXXXX")
    git -C "$tmp" init -q
    git -C "$tmp" config user.name "Test User"
    git -C "$tmp" config user.email "test@example.com"
    git -C "$tmp" config commit.gpgsign false
    echo "$tmp"
}

# Set before calling setup_repo so the merge itself writes that style's
# markers. Setting the style afterwards leaves two-way markers behind, and the
# script's config gate would then be the only thing under test.
conflict_style=""

# Set before calling setup_repo to write a conflict-marker-size attribute,
# which changes how many characters each marker runs for.
marker_size=""

# Leaves the repository mid-merge with every named file (default
# conflict.txt) unmerged. Prints the repository path.
setup_repo() {
    local files=("${@:-conflict.txt}")
    local tmp file
    tmp=$(init_repo "ensure-diff3")
    if [[ -n "$conflict_style" ]]; then
        git -C "$tmp" config merge.conflictStyle "$conflict_style"
    fi
    if [[ -n "$marker_size" ]]; then
        echo "* conflict-marker-size=$marker_size" > "$tmp/.gitattributes"
    fi
    for file in "${files[@]}"; do
        mkdir -p "$(dirname "$tmp/$file")"
        printf 'top\nbase line\nbottom\n' > "$tmp/$file"
        git -C "$tmp" add -- "$file"
    done
    git -C "$tmp" commit -q -m "init"
    local base
    base=$(git -C "$tmp" branch --show-current)
    git -C "$tmp" checkout -q -b theirs
    for file in "${files[@]}"; do
        printf 'top\ntheir line\nbottom\n' > "$tmp/$file"
    done
    git -C "$tmp" commit -q -a -m "theirs"
    git -C "$tmp" checkout -q "$base"
    for file in "${files[@]}"; do
        printf 'top\nour line\nbottom\n' > "$tmp/$file"
    done
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

# cmp compares the bytes. A $(cat) comparison drops trailing newlines, so it
# passes over a file whose only change is at the end.
assert_unchanged() {
    local description="$1" expected="$2" actual="$3"
    if cmp -s "$expected" "$actual"; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        diff "$expected" "$actual" | head -10
        failures=$((failures + 1))
    fi
}

assert_base_section() {
    local description="$1"
    local file="$2"
    local bars
    bars=$(printf '|%.0s' $(seq "${marker_size:-7}"))
    assert_output "$description" "1" "$(grep -cF "$bars" "$file" || true)"
}

# --- Styles that leave git without a base section ---

assert_rewrites_under_style() {
    local style="$1"
    local file="${2:-conflict.txt}"
    local label="${style:-unset} style"
    local repo
    conflict_style="$style"
    repo=$(setup_repo "$file")
    conflict_style=""
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
    conflict_style="$style"
    repo=$(setup_repo)
    conflict_style=""
    assert_base_section "$style style writes a base section itself" "$repo/conflict.txt"
    cp "$repo/conflict.txt" "$repo/before.snapshot"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "$style style prints nothing" "" "$output"
    assert_unchanged "$style style leaves the file untouched" \
        "$repo/before.snapshot" "$repo/conflict.txt"
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
    cp "$repo/conflict.txt" "$repo/before.snapshot"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "existing base section prints nothing" "" "$output"
    assert_unchanged "existing base section survives" \
        "$repo/before.snapshot" "$repo/conflict.txt"
    rm -rf "$repo"
}

# --- Add/add conflict, where the base side is empty ---

test_add_add_conflict() {
    local repo
    repo=$(init_repo "ensure-diff3-addadd")
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
    assert_base_section "add/add adds a base section" "$repo/added.txt"
    assert_output "add/add leaves the base section empty" "" \
        "$(sed -n '/^|||||||/,/^=======/p' "$repo/added.txt" | sed '1d;$d')"
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

# --- A skipped file does not end the loop ---

test_skip_does_not_stop_later_files() {
    local repo
    repo=$(setup_repo "a-skipped.txt" "b-conflict.txt")
    printf 'hand resolved\n' > "$repo/a-skipped.txt"
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "the file after a skipped one is still rewritten" \
        "$(printf 'rewrote\tb-conflict.txt')" "$output"
    assert_output "the skipped file keeps its resolution" "hand resolved" \
        "$(cat "$repo/a-skipped.txt")"
    rm -rf "$repo"
}

# --- Run from a subdirectory, where git reports paths from the top level ---

test_runs_from_subdirectory() {
    local repo
    repo=$(setup_repo "sub/conflict.txt")
    local output
    output=$(cd "$repo/sub" && bash "$SCRIPT")
    assert_output "subdirectory cwd reports the top-level path" \
        "$(printf 'rewrote\tsub/conflict.txt')" "$output"
    assert_base_section "subdirectory cwd rewrites the file" "$repo/sub/conflict.txt"
    rm -rf "$repo"
}

# --- A conflict-marker-size attribute shortens every marker ---

test_short_marker_size() {
    local repo
    marker_size=3
    repo=$(setup_repo)
    local output
    output=$(cd "$repo" && bash "$SCRIPT")
    assert_output "short markers report the rewrite" "$(printf 'rewrote\tconflict.txt')" "$output"
    assert_base_section "short markers gain a base section" "$repo/conflict.txt"
    marker_size=""
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
test_skip_does_not_stop_later_files
test_runs_from_subdirectory
test_short_marker_size
test_filename_with_space
test_outside_repository

# --- Summary ---

echo ""
echo "Results: $passes passed, $failures failed"
if [[ "$failures" -gt 0 ]]; then
    exit 1
fi
