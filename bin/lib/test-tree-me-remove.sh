#!/bin/bash
# Tests for `tree-me remove` argument parsing and its -f/--force handling.
#
# Usage: test-tree-me-remove.sh
#
# Builds a throwaway repo with a few worktrees (clean, dirty, locked) in a temp
# dir, drives bin/tree-me against it, and cleans up on exit.

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
cleanup() {
  # Locked worktrees survive a plain `rm -rf` of the repo's admin files, so
  # unlock everything first rather than leaving stray directories behind.
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null |
    sed -n 's/^worktree //p' |
    while read -r wt; do git -C "$REPO_DIR" worktree unlock "$wt" 2>/dev/null || true; done
  rm -rf "$REPO_DIR" "$WT_BASE"
}
trap cleanup EXIT

git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name "Test"
# A stable default branch name regardless of the host's init.defaultBranch.
git -C "$REPO_DIR" checkout -q -b main
echo one > "$REPO_DIR/file"
git -C "$REPO_DIR" add file
git -C "$REPO_DIR" commit -qm "one"

# Creates a worktree for <branch> at $WT_BASE/<branch> and echoes its path.
mkworktree() {
  local branch="$1" path="$WT_BASE/$1"
  git -C "$REPO_DIR" worktree add -q "$path" -b "$branch" main
  printf '%s\n' "$path"
}

# Runs tree-me inside the fixture repo, capturing combined output in $out and
# the exit status in $rc. Stdin is /dev/null so an unexpected confirmation
# prompt fails the run instead of hanging it.
tree_me() {
  rc=0
  out=$(cd "$REPO_DIR" && WORKTREE_ROOT="$WT_BASE" "$BIN" "$@" </dev/null 2>&1) || rc=$?
}

# Same, but feeds $1 to the confirmation prompt verbatim (no newline is added,
# so callers control whether the answer is newline-terminated).
tree_me_answering() {
  local answer="$1"
  shift
  rc=0
  out=$(printf '%s' "$answer" |
    (cd "$REPO_DIR" && WORKTREE_ROOT="$WT_BASE" "$BIN" "$@" 2>&1)) || rc=$?
}

# ── Test: a clean worktree needs no force ──────────────────────────────────

path=$(mkworktree clean-one)
tree_me rm clean-one
assert "removes a clean worktree without -f" test "$rc" -eq 0
assert "clean worktree directory is gone" test ! -d "$path"

# ── Test: -f removes a worktree with uncommitted changes ───────────────────

path=$(mkworktree dirty-one)
echo changed > "$path/file"
tree_me rm dirty-one
assert "refuses a dirty worktree without -f" test "$rc" -ne 0
assert "dirty worktree survives the refusal" test -d "$path"

tree_me rm -f dirty-one
assert "-f removes a dirty worktree" test "$rc" -eq 0
assert "dirty worktree directory is gone" test ! -d "$path"

# ── Test: the flag is positional-agnostic ──────────────────────────────────

path=$(mkworktree dirty-two)
echo changed > "$path/file"
tree_me rm dirty-two -f
assert "-f is accepted after the branch name" test "$rc" -eq 0
assert "trailing -f removed the worktree" test ! -d "$path"

# ── Test: a locked worktree needs -f twice, as git itself does ─────────────

path=$(mkworktree locked-one)
git -C "$REPO_DIR" worktree lock "$path" --reason "test"
tree_me rm -f locked-one
assert "a single -f leaves a locked worktree alone" test "$rc" -ne 0
assert "locked worktree survives a single -f" test -d "$path"

tree_me rm -f -f locked-one
assert "-f -f removes a locked worktree" test "$rc" -eq 0
assert "locked worktree directory is gone" test ! -d "$path"

path=$(mkworktree locked-two)
git -C "$REPO_DIR" worktree lock "$path" --reason "test"
tree_me rm -ff locked-two
assert "-ff is the same as -f -f" test "$rc" -eq 0
assert "-ff removed the locked worktree" test ! -d "$path"

path=$(mkworktree locked-three)
git -C "$REPO_DIR" worktree lock "$path" --reason "test"
tree_me rm --force --force locked-three
assert "--force --force removes a locked worktree" test "$rc" -eq 0
assert "--force --force removed the worktree directory" test ! -d "$path"

# A single -f on a locked worktree should say who holds the lock and how to
# override it, not leave the user to parse git's advice.
path=$(mkworktree locked-hint)
git -C "$REPO_DIR" worktree lock "$path" --reason '{"owner":"supacode"}'
tree_me rm -f locked-hint
assert "a locked refusal still fails" test "$rc" -ne 0
assert "the hint names the lock holder" test "${out#*supacode}" != "$out"
assert "the hint suggests doubling the flags given" test "${out#*-f -f locked-hint}" != "$out"

path=$(mkworktree locked-hint-plain)
git -C "$REPO_DIR" worktree lock "$path" --reason "test"
tree_me rm locked-hint-plain
assert "a locked refusal without -f fails" test "$rc" -ne 0
assert "the hint suggests one -f when none were given" test "${out#*tree-me remove -f locked-hint-plain}" != "$out"

# Locked wins over dirty: a locked worktree with uncommitted changes still
# needs the doubling, so the hint must not talk about the changes instead.
path=$(mkworktree locked-dirty)
echo changed > "$path/file"
git -C "$REPO_DIR" worktree lock "$path"
tree_me rm -f locked-dirty
assert "a locked dirty refusal fails" test "$rc" -ne 0
assert "a locked dirty worktree gets the lock hint" test "${out#*-f -f locked-dirty}" != "$out"
git -C "$REPO_DIR" worktree unlock "$path"
tree_me rm -ff locked-dirty
assert "-ff removes the unlocked dirty worktree" test "$rc" -eq 0

# The hint reflects a pattern's target the same way.
path=$(mkworktree "locked-batch")
git -C "$REPO_DIR" worktree lock "$path"
tree_me rm -f "locked-b*"
assert "a locked pattern match fails" test "$rc" -ne 0
assert "a locked pattern match gets the -f -f hint" test "${out#*-f -f locked-batch}" != "$out"
git -C "$REPO_DIR" worktree unlock "$path"
tree_me rm -ff "locked-b*"
assert "-ff removes the pattern match" test "$rc" -eq 0

# ── Test: the confirmation a pattern prompts for ───────────────────────────

path_a=$(mkworktree "review-a")
path_b=$(mkworktree "review-b")
tree_me rm "review-*"
assert "a pattern with no answer on stdin aborts" test "$rc" -eq 0
assert "aborted pattern leaves the first worktree" test -d "$path_a"
assert "aborted pattern leaves the second worktree" test -d "$path_b"

tree_me_answering "n"$'\n' rm "review-*"
assert "answering no aborts" test "$rc" -eq 0
assert "a declined pattern leaves both worktrees" test -d "$path_a" -a -d "$path_b"

# Without a trailing newline `read` reports EOF, but it has still read the
# answer, which must count as the yes it is.
tree_me_answering "y" rm "review-*"
assert "answering yes without a newline removes every match" test "$rc" -eq 0
assert "unterminated yes removed the first match" test ! -d "$path_a"
assert "unterminated yes removed the second match" test ! -d "$path_b"

path_a=$(mkworktree "review-c")
path_b=$(mkworktree "review-d")
tree_me_answering "y"$'\n' rm "review-*"
assert "answering yes removes every match" test "$rc" -eq 0
assert "confirmed pattern removed the first match" test ! -d "$path_a"
assert "confirmed pattern removed the second match" test ! -d "$path_b"

# ── Test: -f skips the confirmation entirely ───────────────────────────────

path_a=$(mkworktree "review-e")
path_b=$(mkworktree "review-f")
tree_me rm -f "review-*"
assert "-f removes every match without prompting" test "$rc" -eq 0
assert "first pattern match is gone" test ! -d "$path_a"
assert "second pattern match is gone" test ! -d "$path_b"

# ── Test: a match git refuses doesn't strand the rest of the batch ─────────

path_a=$(mkworktree "batch-a")
path_b=$(mkworktree "batch-b")
path_c=$(mkworktree "batch-c")
git -C "$REPO_DIR" worktree lock "$path_b" --reason "test"
tree_me rm -f "batch-*"
assert "a refused match makes the run fail" test "$rc" -ne 0
assert "the match before the failure is removed" test ! -d "$path_a"
assert "the refused match survives" test -d "$path_b"
assert "the match after the failure is still attempted" test ! -d "$path_c"
assert "the refused match is named in the output" test "${out#*batch-b}" != "$out"
git -C "$REPO_DIR" worktree unlock "$path_b"

# ── Test: bad arguments are reported as such, not treated as branch names ──

tree_me rm -f
assert "a bare -f is a missing-argument error" test "$rc" -ne 0
assert "missing argument does not report -f as a branch" \
  test "${out#*No worktree found}" = "$out"

tree_me rm --bogus some-branch
assert "an unknown option fails" test "$rc" -ne 0
assert "an unknown option says so" test "${out#*Unknown option}" != "$out"

tree_me rm one-branch another-branch
assert "two branch names fail" test "$rc" -ne 0
assert "two branch names report the extra argument" \
  test "${out#*another-branch}" != "$out"

# ── Test: -- ends option parsing ───────────────────────────────────────────

tree_me rm -- -f
assert "-- treats a following -f as the branch name" test "$rc" -ne 0
assert "-- reports the dash-name as a missing worktree" \
  test "${out#*No worktree found}" != "$out"

# ── Results ────────────────────────────────────────────────────────────────

print_results
