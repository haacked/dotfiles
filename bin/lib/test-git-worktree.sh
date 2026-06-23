#!/bin/bash
# Tests for worktree_create in git-worktree.sh.
#
# Usage: test-git-worktree.sh
#
# Builds a throwaway git repo in a temp dir, exercises worktree_create against
# it, and cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/git-worktree.sh
source "$SCRIPT_DIR/git-worktree.sh"

# ── Fixture: a small repo with two commits ─────────────────────────────────

# Resolve through symlinks (macOS /var -> /private/var) so the literal paths
# we build match the canonical paths `git worktree list` reports.
REPO_DIR=$(cd "$(mktemp -d)" && pwd -P)
WT_BASE=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$REPO_DIR" "$WT_BASE"' EXIT

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name "Test"
# A stable default branch name regardless of the host's init.defaultBranch.
git -C "$REPO_DIR" checkout -q -b main
echo one > "$REPO_DIR/file"
git -C "$REPO_DIR" add file
git -C "$REPO_DIR" commit -qm "one"
echo two > "$REPO_DIR/file"
git -C "$REPO_DIR" commit -qam "two"
HEAD_SHA=$(git -C "$REPO_DIR" rev-parse HEAD)
PREV_SHA=$(git -C "$REPO_DIR" rev-parse HEAD~1)

# worktree_create runs git in the current directory, so operate from the repo.
cd "$REPO_DIR"

# ── Test: creates a worktree on a new branch at the given commit ───────────

path="${WT_BASE}/review-repo-1"
out=$(worktree_create "$path" "review-repo-1" "$PREV_SHA")
assert "prints the worktree path it created" test "$out" = "$path"
assert "worktree directory exists" test -d "$path"
assert "worktree HEAD is the requested commit" \
  test "$(git -C "$path" rev-parse HEAD)" = "$PREV_SHA"
assert "new branch was created for the worktree" \
  test "$(git -C "$path" rev-parse --abbrev-ref HEAD)" = "review-repo-1"

# ── Test: idempotent when the branch already has a worktree ────────────────

out=$(worktree_create "${WT_BASE}/somewhere-else" "review-repo-1" "$HEAD_SHA")
assert "re-run returns the existing worktree path, ignoring the new path arg" \
  test "$out" = "$path"
assert "re-run does not create the alternate path" \
  test ! -d "${WT_BASE}/somewhere-else"
assert "re-run leaves the worktree at its original commit" \
  test "$(git -C "$path" rev-parse HEAD)" = "$PREV_SHA"

# ── Test: attaches a worktree to a pre-existing branch ─────────────────────

git branch review-repo-2 "$HEAD_SHA"
path2="${WT_BASE}/review-repo-2"
out=$(worktree_create "$path2" "review-repo-2" "$PREV_SHA")
assert "attaches to an existing branch and prints its path" test "$out" = "$path2"
assert "existing-branch worktree stays at the branch tip, not <committish>" \
  test "$(git -C "$path2" rev-parse HEAD)" = "$HEAD_SHA"

# ── Test: returns non-zero and prints nothing when `git worktree add` fails ──
# prepare_run_dir captures stdout into a path and branches on the exit code, so
# a failure must both return non-zero and emit no path.

mkdir -p "${WT_BASE}/occupied"
echo blocker > "${WT_BASE}/occupied/file"
rc=0
out=$(worktree_create "${WT_BASE}/occupied" "review-repo-3" "$HEAD_SHA" 2>/dev/null) || rc=$?
assert "returns non-zero when git worktree add fails" test "$rc" -ne 0
assert "prints nothing on failure so the caller captures no path" test -z "$out"

# ── Results ────────────────────────────────────────────────────────────────

print_results
