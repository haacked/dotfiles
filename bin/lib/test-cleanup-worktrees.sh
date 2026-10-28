#!/bin/bash
# Tests for bin/cleanup-modules/worktrees.sh: orphaned worktree directory
# detection and the merged-PR worktree removal guard.
#
# Usage: test-cleanup-worktrees.sh
#
# Builds a throwaway repo and worktree roots under a fake HOME, stubs gh, and
# drives the module's functions directly.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/cleanup-modules/worktrees.sh
source "$SCRIPT_DIR/../cleanup-modules/worktrees.sh"

log_message() { echo "$1"; }
# Like disk-cleanup's run_cleanup, this stub reports a failed command and
# continues. A removal that fails then shows up as a failed assertion.
run_cleanup() {
  [ "$DRY_RUN" = true ] && return 0
  eval "$2" || echo "Failed: $1"
}
DRY_RUN=false

# Resolve through symlinks (macOS /var -> /private/var) so the literal paths we
# build match the canonical paths the module compares.
FAKE_HOME=$(cd "$(mktemp -d)" && pwd -P)
STUB_DIR="$FAKE_HOME/stubs"
REPO_DIR="$FAKE_HOME/dev/acme/widgets"
ROOT="$FAKE_HOME/dev/worktrees"
cleanup() {
  git -C "$REPO_DIR" worktree list --porcelain 2>/dev/null |
    sed -n 's/^worktree //p' |
    while read -r wt; do git -C "$REPO_DIR" worktree unlock "$wt" 2>/dev/null || true; done
  chmod -R u+w "$FAKE_HOME"
  rm -rf "$FAKE_HOME"
}
trap cleanup EXIT

mkdir -p "$STUB_DIR" "$REPO_DIR" "$ROOT"
git -C "$REPO_DIR" init -q
git -C "$REPO_DIR" config user.email test@example.com
git -C "$REPO_DIR" config user.name "Test"
git -C "$REPO_DIR" checkout -q -b main
git -C "$REPO_DIR" remote add origin https://github.com/acme/widgets.git
echo one > "$REPO_DIR/file"
git -C "$REPO_DIR" add file
git -C "$REPO_DIR" commit -qm "one"

mkworktree() {
  local branch="$1" path="$ROOT/widgets/$1"
  git -C "$REPO_DIR" worktree add -q "$path" -b "$branch" main
  printf '%s\n' "$path"
}

# Sets the mtime of every entry under the given paths to 2020, so the module's
# freshness guard treats them as settled rather than as a worktree being created.
age() { find "$@" -exec touch -h -t 202001010000 {} +; }

# lsof stub: prints each line of $LSOF_STUB/cwds as a process working directory.
LSOF_STUB="$FAKE_HOME/lsof-stub"
mkdir -p "$LSOF_STUB"
echo /elsewhere >"$LSOF_STUB/cwds"
cat >"$LSOF_STUB/lsof" <<'STUB'
#!/bin/bash
while IFS= read -r cwd; do printf 'p1\nfcwd\nn%s\n' "$cwd"; done <"$(dirname "$0")/cwds"
STUB
chmod +x "$LSOF_STUB/lsof"
ORPHAN_PATH="$LSOF_STUB:/usr/bin:/bin"

# supacode stub: every command fails when $STUB_DIR/down exists.
# `supacode worktree list` prints $STUB_DIR/ids, and `supacode tab list
# --worktree <id>` prints $STUB_DIR/tabs-<id> when present.
cat >"$STUB_DIR/supacode" <<'STUB'
#!/bin/bash
dir="$(dirname "$0")"
command="$1 $2"
id=""
while [ $# -gt 0 ]; do
  [ "$1" = "--worktree" ] && id="$2"
  shift
done
if [ -e "$dir/down" ]; then echo "Error: Supacode is not running" >&2; exit 1; fi
case "$command" in
  "worktree list") cat "$dir/ids" 2>/dev/null ;;
  "tab list") [ -f "$dir/tabs-$id" ] && cat "$dir/tabs-$id" ;;
esac
exit 0
STUB
chmod +x "$STUB_DIR/supacode"
supacode_id() { jq -rn --arg p "$1/" '$p | @uri'; }
# Registers path $1 with the Supacode stub, with an open tab when $2 is "tab".
supacode_register() {
  local id
  id=$(supacode_id "$1")
  echo "$id" >>"$STUB_DIR/ids"
  if [ "${2:-}" = tab ]; then echo "TAB-1" >"$STUB_DIR/tabs-$id"; fi
}

# gh stub: `gh pr list --head <branch> ...` prints $STUB_DIR/pr-<branch>.json,
# with slashes in the branch replaced by dashes, or [] when that file is absent.
cat >"$STUB_DIR/gh" <<'STUB'
#!/bin/bash
branch=""
while [ $# -gt 0 ]; do
  [ "$1" = "--head" ] && branch="$2"
  shift
done
file="$(dirname "$0")/pr-${branch//\//-}.json"
if [ -f "$file" ]; then cat "$file"; else echo '[]'; fi
STUB
chmod +x "$STUB_DIR/gh"
stub_merged_pr() {
  local branch="$1" oid="$2"
  printf '[{"number":42,"headRefOid":"%s"}]\n' "$oid" >"$STUB_DIR/pr-${branch//\//-}.json"
}

scan() { scan_worktree_dir "$ROOT" 0; }
has_line() { grep -qxF "$1" <<<"$2"; }

# Runs the module under the fake HOME with PATH $1 and the mode in $2.
run_module() { ( HOME="$FAKE_HOME" PATH="$1" cleanup_worktrees "$2" >/dev/null ); }
merged_pr() { PATH="$STUB_DIR:$PATH" merged_pr_for_worktree "$1"; }
removable() { ! worktree_removal_blocker "$@" >/dev/null; }

# Gives $1 a read-only directory tree, like a Go module cache.
mk_readonly_gomod() {
  mkdir -p "$1/.flox/cache/go/mod/pkg"
  echo x >"$1/.flox/cache/go/mod/pkg/file"
  chmod 555 "$1/.flox/cache/go/mod/pkg" "$1/.flox/cache/go/mod"
}

# ── Orphan detection ──────────────────────────────────────────────────────

live=$(mkworktree haacked/live)

# A checkout whose admin dir git has since dropped.
stale=$(mkworktree haacked/stale)
git -C "$REPO_DIR" worktree remove --force "$stale"
mkdir -p "$stale/src"
echo "gitdir: $REPO_DIR/.git/worktrees/stale" >"$stale/.git"
echo work >"$stale/src/file"

# A copy of a live worktree: its admin dir points at the original, not here.
copy="$ROOT/widgets/haacked/copy"
mkdir -p "$copy"
cp "$live/.git" "$copy/.git"

# Leftovers a running process recreated after the worktree was removed.
residue="$ROOT/widgets/haacked/residue"
mkdir -p "$residue/.flox/log"
echo log >"$residue/.flox/log/run.log"

# The module reports a repo directory with no live worktree once, at the top.
mkdir -p "$ROOT/gadgets/haacked/one/node_modules/pkg" "$ROOT/gadgets/haacked/two"
echo x >"$ROOT/gadgets/haacked/one/node_modules/pkg/index.js"
echo x >"$ROOT/gadgets/haacked/two/log"

# Leftovers holding a read-only directory, like a Go module cache.
readonly_orphan="$ROOT/widgets/haacked/readonly"
mk_readonly_gomod "$readonly_orphan"

# Leftovers that a process still has as its working directory.
busy_orphan="$ROOT/widgets/haacked/busy"
mkdir -p "$busy_orphan/logs"
echo log >"$busy_orphan/logs/run.log"
echo "$busy_orphan/logs" >>"$LSOF_STUB/cwds"

# Directories with nothing to reclaim.
mkdir -p "$ROOT/widgets/empty" "$ROOT/widgets/ds-store-only/haacked/nested"
touch "$ROOT/widgets/ds-store-only/haacked/.DS_Store"

# A full clone is never an orphan.
git clone -q "$REPO_DIR" "$ROOT/clone"

# A live worktree deeper than the scan looks.
git -C "$REPO_DIR" worktree add -q "$ROOT/deep/a/b/c/d/e" -b haacked/a/b/c/d/e main

# A live worktree in a hidden directory of leftovers, like a Claude agent worktree.
hidden_parent="$ROOT/hidden/haacked/residue"
mkdir -p "$hidden_parent/logs"
echo log >"$hidden_parent/logs/run.log"
git -C "$REPO_DIR" worktree add -q "$hidden_parent/.claude/worktrees/agent" -b agent-hidden main

# A live worktree nested inside a checkout whose admin dir git dropped.
nested_stale="$ROOT/nested/haacked/stale"
mkdir -p "$nested_stale"
echo "gitdir: $REPO_DIR/.git/worktrees/nested-stale" >"$nested_stale/.git"
git -C "$REPO_DIR" worktree add -q "$nested_stale/.claude/worktrees/agent" -b agent-nested main

# Worktrees of a repo that was renamed afterward. git worktree repair recovers them.
moved_repo="$FAKE_HOME/dev/acme/renamed"
git clone -q "$REPO_DIR" "$moved_repo"
git -C "$moved_repo" worktree add -q "$ROOT/renamed/haacked/wt" -b wt
echo work >"$ROOT/renamed/haacked/wt/work.txt"
mv "$moved_repo" "$moved_repo-new"
mkdir -p "$ROOT/renamed/haacked/residue"
echo log >"$ROOT/renamed/haacked/residue/run.log"

# A live worktree moved with mv. Its admin dir still records the old path.
git -C "$REPO_DIR" worktree add -q "$ROOT/widgets/haacked/before-move" -b moved main
mv "$ROOT/widgets/haacked/before-move" "$ROOT/widgets/haacked/after-move"

# A live worktree whose .git file has no trailing newline.
no_newline=$(mkworktree haacked/no-newline)
printf 'gitdir: %s' "$REPO_DIR/.git/worktrees/no-newline" >"$no_newline/.git"

# A stale checkout holding a package that ships a submodule .git file whose
# relative gitdir names a repo inside the checkout that does not exist.
packaged="$ROOT/widgets/haacked/packaged"
mkdir -p "$packaged/.venv/site-packages/pkg/core"
echo "gitdir: $REPO_DIR/.git/worktrees/packaged" >"$packaged/.git"
echo "gitdir: ../../.git/modules/core" >"$packaged/.venv/site-packages/pkg/core/.git"
echo x >"$packaged/.venv/site-packages/pkg/core/lib.py"

# A live worktree that git recorded through a differently cased path. APFS
# ignores case, so both spellings name the same directory.
cased="$ROOT/widgets/haacked/cased"
git -C "$REPO_DIR" worktree add -q "$FAKE_HOME/dev/WORKTREES/widgets/haacked/cased" -b cased main
echo work >"$cased/work.txt"

# A live worktree with edits next to leftovers whose name holds a newline.
feature=$(mkworktree haacked/feature)
echo work >"$feature/work.txt"
mkdir -p "$ROOT/widgets/haacked/feature
x"
echo log >"$ROOT/widgets/haacked/feature
x/run.log"

# Leftovers a process works in, under a root that is a symlink. lsof reports
# the resolved path.
REVIEW_REAL="$FAKE_HOME/review-real"
mkdir -p "$REVIEW_REAL/repo/busy" "$FAKE_HOME/.agents/skills/review-code"
ln -s "$REVIEW_REAL" "$FAKE_HOME/.agents/skills/review-code/.worktrees"
echo log >"$REVIEW_REAL/repo/busy/run.log"
echo "$REVIEW_REAL/repo/busy" >>"$LSOF_STUB/cwds"

# A stale checkout with an old top directory and a file edited just now.
deep_edit="$ROOT/widgets/haacked/deep-edit"
mkdir -p "$deep_edit/src"
echo "gitdir: $REPO_DIR/.git/worktrees/deep-edit" >"$deep_edit/.git"
echo old >"$deep_edit/src/file"

age "$ROOT" "$REVIEW_REAL"

# A directory changed just now, next to old leftovers whose name extends it with
# a newline.
mkdir -p "$ROOT/widgets/haacked/recent"
echo work >"$ROOT/widgets/haacked/recent/work.txt"
mkdir -p "$ROOT/widgets/haacked/recent
x"
echo log >"$ROOT/widgets/haacked/recent
x/run.log"
age "$ROOT/widgets/haacked/recent
x"
echo new >"$deep_edit/src/file"

# Created within the freshness window, like a worktree mid-checkout.
fresh="$ROOT/widgets/haacked/fresh"
mkdir -p "$fresh"
echo x >"$fresh/file"

out=$(scan)
assert "live worktree is reported as a worktree" has_line "worktree	$live" "$out"
assert "full clone is reported as a worktree" has_line "worktree	$ROOT/clone" "$out"
assert "checkout whose admin dir is gone is an orphan" has_line "orphan	$stale" "$out"
assert "copy pointing at another worktree's admin dir is an orphan" has_line "orphan	$copy" "$out"
assert "residue without .git is an orphan" has_line "orphan	$residue" "$out"
assert "repo dir with no live worktree is reported once at the top" has_line "orphan	$ROOT/gadgets" "$out"
assert_not "leaves under an orphaned repo dir are not reported separately" has_line "orphan	$ROOT/gadgets/haacked/one" "$out"
assert_not "live worktree is not an orphan" has_line "orphan	$live" "$out"
assert_not "parent of a live worktree is not an orphan" has_line "orphan	$ROOT/widgets/haacked" "$out"
assert_not "full clone is not an orphan" has_line "orphan	$ROOT/clone" "$out"
assert_not "empty dir is not reported" has_line "orphan	$ROOT/widgets/empty" "$out"
assert_not "dir holding only empty dirs and .DS_Store is not reported" has_line "orphan	$ROOT/widgets/ds-store-only" "$out"
assert_not "freshly created dir is not reported" has_line "orphan	$fresh" "$out"
assert_not "dir holding a live worktree deeper than the scan is not an orphan" has_line "orphan	$ROOT/deep" "$out"
assert_not "leftovers holding a live worktree in a hidden dir are not an orphan" has_line "orphan	$ROOT/hidden" "$out"
assert_not "stale checkout holding a live worktree is not an orphan" has_line "orphan	$ROOT/nested" "$out"
assert_not "worktree of a renamed repo is not an orphan" has_line "orphan	$ROOT/renamed" "$out"
assert "leftovers next to a renamed repo's worktree are an orphan" has_line "orphan	$ROOT/renamed/haacked/residue" "$out"
assert_not "worktree moved with mv is not an orphan" has_line "orphan	$ROOT/widgets/haacked/after-move" "$out"
assert "worktree whose .git file has no trailing newline is live" has_line "worktree	$no_newline" "$out"
assert "stale checkout holding a dangling packaged .git file is an orphan" has_line "orphan	$packaged" "$out"
assert_not "stale checkout with a file edited just now is not reported" has_line "orphan	$deep_edit" "$out"
assert "worktree recorded through a differently cased path is live" has_line "worktree	$cased" "$out"
assert_not "worktree recorded through a differently cased path is not an orphan" has_line "orphan	$cased" "$out"

# A submodule-style .git file points at an admin dir with no gitdir file.
sub="$ROOT/widgets/sub"
mkdir -p "$sub" "$REPO_DIR/.git/modules/sub"
echo "gitdir: $REPO_DIR/.git/modules/sub" >"$sub/.git"
age "$sub"
assert_not "dir whose admin dir exists without a gitdir file is not an orphan" has_line "orphan	$sub" "$(scan)"
rm -rf "$sub" "$REPO_DIR/.git/modules"

# ── Orphan removal by mode ───────────────────────────────────────────────

run_module "$ORPHAN_PATH" conservative
assert "conservative mode keeps orphans" test -d "$residue"
assert "conservative mode keeps the stale checkout" test -f "$stale/src/file"

mv "$LSOF_STUB/cwds" "$LSOF_STUB/cwds.saved"
: >"$LSOF_STUB/cwds"
run_module "$ORPHAN_PATH" aggressive
assert "aggressive mode keeps orphans when lsof reports nothing" test -d "$residue"
mv "$LSOF_STUB/cwds.saved" "$LSOF_STUB/cwds"

git -C "$REPO_DIR" worktree prune
run_module "$ORPHAN_PATH" aggressive
assert_not "aggressive mode removes residue" test -e "$residue"
assert "aggressive mode keeps a stale checkout, which may hold edits" test -f "$stale/src/file"
assert "aggressive mode keeps a copy of a worktree, which may hold edits" test -f "$copy/.git"
assert "aggressive mode keeps a worktree moved with mv after git pruned it" test -f "$ROOT/widgets/haacked/after-move/file"
assert "aggressive mode keeps the worktree recorded through a differently cased path" test -f "$cased/work.txt"
assert "aggressive mode keeps a worktree next to a name with a newline" test -f "$feature/work.txt"
assert "aggressive mode keeps a recent dir next to a name with a newline" test -f "$ROOT/widgets/haacked/recent/work.txt"
assert "aggressive mode keeps leftovers a process works in under a symlinked root" test -f "$REVIEW_REAL/repo/busy/run.log"
assert_not "aggressive mode removes the orphaned repo dir" test -e "$ROOT/gadgets"
assert "aggressive mode keeps the live worktree" test -f "$live/file"
assert "aggressive mode keeps the full clone" test -d "$ROOT/clone/.git"
assert "aggressive mode keeps the fresh dir" test -d "$fresh"
assert_not "aggressive mode removes an orphan holding a read-only dir" test -e "$readonly_orphan"
assert "aggressive mode keeps an orphan a process works in" test -f "$busy_orphan/logs/run.log"
assert "aggressive mode keeps a live worktree deeper than the scan" test -f "$ROOT/deep/a/b/c/d/e/file"
assert "aggressive mode keeps a live worktree in a hidden dir" test -f "$hidden_parent/.claude/worktrees/agent/file"
assert "aggressive mode keeps a live worktree inside a stale checkout" test -f "$nested_stale/.claude/worktrees/agent/file"
assert "aggressive mode keeps the renamed repo's worktree" test -f "$ROOT/renamed/haacked/wt/work.txt"
assert "aggressive mode keeps the worktree moved with mv" test -f "$ROOT/widgets/haacked/after-move/file"

DRY_RUN=true run_module "$ORPHAN_PATH" aggressive
assert "dry run keeps the fresh dir" test -d "$fresh"

# ── Merged-PR worktrees ──────────────────────────────────────────────────

printf '.flox/\n.claude/\nnode_modules/\n.notes/\n' >>"$REPO_DIR/.git/info/exclude"
merged_clean=$(mkworktree haacked/merged-clean)
merged_case=$(mkworktree haacked/merged-case)
merged_locked=$(mkworktree haacked/merged-locked)
merged_notes=$(mkworktree haacked/merged-notes)
merged_skip=$(mkworktree haacked/merged-skip)
merged_nested=$(mkworktree haacked/merged-nested)
merged_tab=$(mkworktree haacked/merged-tab)
merged_busy=$(mkworktree haacked/merged-busy)
merged_unknown=$(mkworktree haacked/merged-unknown)
merged_dirty=$(mkworktree haacked/merged-dirty)
merged_ahead=$(mkworktree haacked/merged-ahead)
unmerged=$(mkworktree haacked/unmerged)
detached="$ROOT/widgets/detached"
git -C "$REPO_DIR" worktree add -q --detach "$detached" main
git -C "$REPO_DIR" worktree lock --reason '{"owner":"supacode","version":"0.11.6"}' "$merged_clean"
git -C "$REPO_DIR" worktree lock --reason "manual" "$merged_locked"

for wt in "$merged_clean" "$merged_case" "$merged_locked" "$merged_notes" "$merged_skip" "$merged_nested" "$merged_tab" "$merged_busy" "$merged_unknown" "$merged_dirty" "$merged_ahead"; do
  stub_merged_pr "haacked/$(basename "$wt")" "$(git -C "$wt" rev-parse HEAD)"
done
mk_readonly_gomod "$merged_clean"
mkdir -p "$merged_clean/node_modules/pkg"
echo x >"$merged_clean/node_modules/pkg/index.js"
mkdir -p "$merged_notes/.notes"
echo notes >"$merged_notes/.notes/handoff.md"
echo edit >"$merged_skip/file"
git -C "$merged_skip" update-index --skip-worktree file
git -C "$REPO_DIR" worktree add -q "$merged_nested/.claude/worktrees/agent" -b agent-merged main
echo work >"$merged_nested/.claude/worktrees/agent/work.txt"
supacode_register "$merged_clean"
supacode_register "$merged_tab" tab
supacode_register "$(dirname "$merged_case")/MERGED-CASE" tab
echo "$merged_busy" >>"$LSOF_STUB/cwds"
echo edit >"$merged_dirty/file"
echo more >"$merged_ahead/file"
git -C "$merged_ahead" commit -qam "after merge"
rm -rf "$fresh"

assert "merged worktree reports the PR number and merged head" \
  test "$(merged_pr "$merged_clean")" = "42	$(git -C "$merged_clean" rev-parse HEAD)"
assert_not "worktree without a merged PR reports nothing" merged_pr "$unmerged"
assert_not "detached worktree reports nothing" merged_pr "$detached"

assert "clean merged worktree with ignored build output is removable" removable "$merged_clean" "$(git -C "$merged_clean" rev-parse HEAD)"
assert_not "merged worktree with uncommitted changes is not removable" \
  removable "$merged_dirty" "$(git -C "$REPO_DIR" rev-parse main)"
assert_not "merged worktree with commits after the merged head is not removable" \
  removable "$merged_ahead" "$(git -C "$REPO_DIR" rev-parse main)"
echo untracked >"$merged_clean/new-file"
assert_not "merged worktree with untracked files is not removable" \
  removable "$merged_clean" "$(git -C "$merged_clean" rev-parse HEAD)"
git -C "$REPO_DIR" config status.showUntrackedFiles no
assert_not "untracked files count even when the repo hides them from status" \
  removable "$merged_clean" "$(git -C "$merged_clean" rev-parse HEAD)"
git -C "$REPO_DIR" config --unset status.showUntrackedFiles
rm "$merged_clean/new-file"

broken_index=$(mkworktree haacked/broken-index)
echo edit >"$broken_index/file"
echo garbage >"$(git -C "$broken_index" rev-parse --git-dir)/index"
assert_not "worktree whose status cannot be read is not removable" \
  removable "$broken_index" "$(git -C "$REPO_DIR" rev-parse main)"
git -C "$REPO_DIR" worktree remove --force "$broken_index"

assert_not "merged worktree holding another worktree is not removable" \
  removable "$merged_nested" "$(git -C "$merged_nested" rev-parse HEAD)"
assert_not "merged worktree with ignored notes is not removable" \
  removable "$merged_notes" "$(git -C "$merged_notes" rev-parse HEAD)"
assert_not "merged worktree with a skip-worktree edit is not removable" \
  removable "$merged_skip" "$(git -C "$merged_skip" rev-parse HEAD)"
assert_not "merged worktree with a lock Supacode does not hold is not removable" \
  removable "$merged_locked" "$(git -C "$merged_locked" rev-parse HEAD)"

without_supacode() { PATH=/usr/bin:/bin supacode_may_have_session "$1"; }
assert "a missing supacode CLI counts as a possible session" without_supacode "$merged_clean"

MERGED_PATH="$STUB_DIR:$LSOF_STUB:$PATH"
run_module "$MERGED_PATH" conservative
assert "conservative mode keeps the merged worktree" test -d "$merged_clean"

touch "$STUB_DIR/down"
run_module "$MERGED_PATH" aggressive
assert "aggressive mode keeps merged worktrees when Supacode cannot answer" test -d "$merged_clean"
rm "$STUB_DIR/down"

run_module "$MERGED_PATH" aggressive
assert_not "aggressive mode removes the clean, locked merged worktree with a read-only dir" test -e "$merged_clean"
assert_not "aggressive mode removes a merged worktree Supacode does not know" test -e "$merged_unknown"
assert "aggressive mode keeps a merged worktree with an open Supacode tab" test -d "$merged_tab"
assert "aggressive mode keeps a merged worktree Supacode knows by another spelling with a tab" test -d "$merged_case"
assert "aggressive mode keeps a merged worktree with ignored notes" test -f "$merged_notes/.notes/handoff.md"
assert "aggressive mode keeps a merged worktree with a skip-worktree edit" test -d "$merged_skip"
assert "aggressive mode keeps a merged worktree with a manual lock" test -d "$merged_locked"
assert "aggressive mode keeps a merged worktree a process works in" test -d "$merged_busy"
assert "aggressive mode keeps a merged worktree holding another worktree" test -f "$merged_nested/.claude/worktrees/agent/work.txt"
assert_not "git no longer lists the removed merged worktree" \
  grep -qxF "worktree $merged_clean" <<<"$(git -C "$REPO_DIR" worktree list --porcelain)"
assert "aggressive mode keeps the dirty merged worktree" test -f "$merged_dirty/file"
assert "aggressive mode keeps the merged worktree with later commits" test -d "$merged_ahead"
assert "aggressive mode keeps the unmerged worktree" test -d "$unmerged"
assert "aggressive mode keeps the detached worktree" test -d "$detached"
assert "aggressive mode keeps the merged branch" git -C "$REPO_DIR" show-ref --verify --quiet refs/heads/haacked/merged-clean

print_results
