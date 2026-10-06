#!/bin/bash
# Tests for `tree-me create`, focused on the parent it records for stacked
# branches.
#
# Usage: test-tree-me-create.sh
#
# Builds a throwaway repo (main, plus a `parent` branch one commit ahead) in a
# temp dir, drives bin/tree-me against it, and cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
BIN="$(cd "$SCRIPT_DIR/.." && pwd)/tree-me"

# ── Fixture: a repo whose worktrees live under $WT_BASE ────────────────────

# Resolve through symlinks (macOS /var -> /private/var) so the literal paths we
# build match the canonical paths `git worktree list` reports.
REPO_DIR=$(cd "$(mktemp -d)" && pwd -P)
WT_BASE=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$REPO_DIR" "$WT_BASE"' EXIT

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name "Test"
git -C "$REPO_DIR" config commit.gpgsign false
# A stable default branch name regardless of the host's init.defaultBranch.
git -C "$REPO_DIR" checkout -q -b main
echo one > "$REPO_DIR/file"
git -C "$REPO_DIR" add file
git -C "$REPO_DIR" commit -qm "one"
git -C "$REPO_DIR" checkout -q -b parent
echo two > "$REPO_DIR/file"
git -C "$REPO_DIR" commit -qam "two"
git -C "$REPO_DIR" checkout -q main

# Runs tree-me inside the fixture repo, capturing combined output in $out and
# the exit status in $rc. Stdin is /dev/null so an unexpected prompt fails the
# run instead of hanging it.
tree_me() {
  rc=0
  out=$(cd "$REPO_DIR" && WORKTREE_ROOT="$WT_BASE" "$BIN" "$@" </dev/null 2>&1) || rc=$?
}

# Echoes branch.<name>.parent for the given branch, or nothing when unset.
recorded_parent() {
  git -C "$REPO_DIR" config --get "branch.$1.parent" || true
}

# ── Test: an explicit base is recorded as the branch's parent ──────────────

tree_me create stacked parent
assert "create with a base exits 0" test "$rc" -eq 0
assert "create with a base records it as the parent" test "$(recorded_parent stacked)" = parent

# ── Test: a base that names a branch indirectly records the branch ─────────

git -C "$REPO_DIR" checkout -q parent
tree_me create from-head HEAD
git -C "$REPO_DIR" checkout -q main
assert "create from HEAD exits 0" test "$rc" -eq 0
assert "create from HEAD records the checked-out branch" test "$(recorded_parent from-head)" = parent

git -C "$REPO_DIR" update-ref refs/remotes/origin/parent parent
tree_me create from-remote origin/parent
assert "create from a remote-tracking base exits 0" test "$rc" -eq 0
assert "create from a remote-tracking base records the bare branch name" \
  test "$(recorded_parent from-remote)" = parent

# ── Test: a base that is not a branch records no parent ────────────────────

# gh pr create --base accepts only a branch name.
tree_me create from-sha "$(git -C "$REPO_DIR" rev-parse parent)"
assert "create from a SHA exits 0" test "$rc" -eq 0
assert "create from a SHA records no parent" test -z "$(recorded_parent from-sha)"

git -C "$REPO_DIR" tag v1 parent
tree_me create from-tag v1
assert "create from a tag exits 0" test "$rc" -eq 0
assert "create from a tag records no parent" test -z "$(recorded_parent from-tag)"

# ── Test: no base means no recorded parent ─────────────────────────────────

tree_me create plain
assert "create without a base exits 0" test "$rc" -eq 0
assert "create without a base records no parent" test -z "$(recorded_parent plain)"

# ── Test: an existing worktree is left alone ───────────────────────────────

tree_me create plain parent
assert "create for an existing worktree exits 0" test "$rc" -eq 0
assert "create for an existing worktree records no parent" test -z "$(recorded_parent plain)"

# ── Results ────────────────────────────────────────────────────────────────

print_results
