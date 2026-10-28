#!/bin/bash
# Tests for git-bclean-local's worktree removal.
#
# Usage: test-git-bclean-local.sh
#
# Builds a throwaway repo whose branches track a remote branch that is gone,
# gives each branch a worktree, runs bin/git-bclean-local against it, and
# cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
BIN="$(cd "$SCRIPT_DIR/.." && pwd)/git-bclean-local"
find_bash4

# ── Fixture: a repo whose worktrees live under $WT_BASE ────────────────────

# Resolve through symlinks (macOS /var -> /private/var) so the literal paths we
# build match the canonical paths `git worktree list` reports.
REPO_DIR=$(cd "$(mktemp -d)" && pwd -P)
WT_BASE=$(cd "$(mktemp -d)" && pwd -P)
cleanup() {
  # A plain `rm -rf` of the repo's admin files leaves locked worktrees behind.
  # The loop unlocks every worktree first.
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null |
    sed -n 's/^worktree //p' |
    while read -r wt; do git -C "$REPO_DIR" worktree unlock "$wt" 2>/dev/null || true; done
  # `rm -rf` cannot empty a read-only directory.
  chmod -R u+w "$REPO_DIR" "$WT_BASE" 2>/dev/null || true
  rm -rf "$REPO_DIR" "$WT_BASE"
}
trap cleanup EXIT

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name "Test"
git -C "$REPO_DIR" checkout -q -b main
echo one > "$REPO_DIR/file"
# git ignores cache/ the way posthog ignores .flox/cache. A read-only directory
# under it then leaves the worktree clean.
echo cache/ > "$REPO_DIR/.gitignore"
git -C "$REPO_DIR" add file .gitignore
git -C "$REPO_DIR" commit -qm "one"
# The remote is never fetched. A branch whose upstream ref is missing reports
# [gone], which is what gh poi leaves behind after a merge.
git -C "$REPO_DIR" remote add origin "$REPO_DIR/no-such-remote"

# Creates a worktree for <branch> at $WT_BASE/<branch>, makes the branch track
# a gone remote branch, gives the worktree a read-only directory, and echoes
# that directory's path.
mkgoneworktree() {
  local branch="$1" path="$WT_BASE/$1"
  git -C "$REPO_DIR" worktree add -q "$path" -b "$branch" main
  git -C "$REPO_DIR" config "branch.$branch.remote" origin
  git -C "$REPO_DIR" config "branch.$branch.merge" "refs/heads/$branch"
  mkreadonlydir "$path"
}

branch_exists() {
  git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$1"
}

mkgoneworktree gone-clean >/dev/null
mkgoneworktree gone-missing >/dev/null
chmod -R u+w "$WT_BASE/gone-missing"
rm -rf "$WT_BASE/gone-missing"
dir_dirty=$(mkgoneworktree gone-dirty)
echo changed > "$WT_BASE/gone-dirty/file"
dir_locked=$(mkgoneworktree gone-locked)
git -C "$REPO_DIR" worktree lock "$WT_BASE/gone-locked" --reason '{"owner":"supacode"}'

# git refuses to remove the main worktree, so its permissions must not change.
git -C "$REPO_DIR" config branch.main.remote origin
git -C "$REPO_DIR" config branch.main.merge refs/heads/main
dir_main=$(mkreadonlydir "$REPO_DIR")

rc=0
out=$(cd "$REPO_DIR" && "$BASH4" "$BIN" 2>&1) || rc=$?

# ── Test: a read-only directory doesn't stop the removal partway ──────────

assert "the run succeeds" test "$rc" -eq 0
assert "removes a worktree holding a read-only directory" test ! -e "$WT_BASE/gone-clean"
assert_not "deletes the branch of the removed worktree" branch_exists gone-clean

assert_not "deletes the branch of a worktree whose directory is gone" branch_exists gone-missing

# ── Test: skipped worktrees keep their permissions ─────────────────────────

assert "skips a dirty worktree" test -e "$dir_dirty"
assert "keeps the dirty worktree's branch" branch_exists gone-dirty
assert_not "a skipped dirty worktree's directory stays read-only" test -w "$dir_dirty"

assert "skips a locked worktree" test -e "$dir_locked"
assert "keeps the locked worktree's branch" branch_exists gone-locked
assert "names the lock holder" test "${out#*locked by supacode}" != "$out"
assert_not "a skipped locked worktree's directory stays read-only" test -w "$dir_locked"

assert "keeps the main worktree's branch" branch_exists main
assert_not "the main worktree's directory stays read-only" test -w "$dir_main"

# ── Results ────────────────────────────────────────────────────────────────

print_results
