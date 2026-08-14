#!/bin/bash
# Tests for git-pr-base.sh: stack-aware resolution of the base branch a PR
# from HEAD targets.
#
# Usage: test-git-pr-base.sh
#
# Builds a throwaway upstream repo with a stacked topology (main: m1,m2 →
# parent: p1,p2 → child: c1,c2), clones it so origin/* refs exist, and drives
# git-pr-base.sh as a subprocess from the clone with `child` checked out. The
# helper's gh/gt calls hit PATH shims whose answers are driven by env vars
# (GH_TSV/GH_RC/GH_SLEEP, GT_PARENT/GT_RC), so every case is fully offline;
# the controlled PATH keeps system git visible and the real gh/gt invisible.
# Cleans up on exit.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

BIN="$SCRIPT_DIR/git-pr-base.sh"

# ── Fixture: stacked upstream, work clone, gh/gt shims ──────────────────────

# Resolve through symlinks (macOS /var -> /private/var) so paths stay stable.
TESTTMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TESTTMP"' EXIT

UPSTREAM="$TESTTMP/upstream"
WORK="$TESTTMP/work"

mkdir -p "$UPSTREAM"
git -C "$UPSTREAM" init -q
git -C "$UPSTREAM" config user.email test@example.com
git -C "$UPSTREAM" config user.name "Test"
git -C "$UPSTREAM" config commit.gpgsign false
# A stable default branch name regardless of the host's init.defaultBranch.
git -C "$UPSTREAM" checkout -q -b main

up_commit() {  # $1 = file name, doubles as the commit message
  echo "$1" > "$UPSTREAM/$1"
  git -C "$UPSTREAM" add "$1"
  git -C "$UPSTREAM" commit -qm "$1"
}

up_commit m1
up_commit m2
git -C "$UPSTREAM" checkout -q -b parent
up_commit p1
up_commit p2
git -C "$UPSTREAM" checkout -q -b child
up_commit c1
up_commit c2
# Checked out last so the clone's origin/HEAD points at main.
git -C "$UPSTREAM" checkout -q main

git clone -q "$UPSTREAM" "$WORK"
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name "Test"
git -C "$WORK" config commit.gpgsign false
git -C "$WORK" checkout -q child
M1_SHA=$(git -C "$WORK" rev-parse origin/main~1)

# gh/gt shims: canned answers driven by env vars, so each invocation controls
# what the "network" says. GH_TSV is the post-jq TSV line the helper parses
# (<baseRefName>\t<prNumber>); the shims ignore their arguments.
SHIM_PATH="$TESTTMP/bin:/usr/bin:/bin"
mkdir -p "$TESTTMP/bin"

make_shims() {
  cat > "$TESTTMP/bin/gh" <<'SHIM'
#!/bin/bash
[ -n "${GH_SLEEP-}" ] && sleep "$GH_SLEEP"
[ -n "${GH_RC-}" ] && exit "$GH_RC"
printf '%s\n' "${GH_TSV-}"
SHIM
  cat > "$TESTTMP/bin/gt" <<'SHIM'
#!/bin/bash
[ -n "${GT_SLEEP-}" ] && sleep "$GT_SLEEP"
[ -n "${GT_RC-}" ] && exit "$GT_RC"
printf '%s\n' "${GT_PARENT-}"
SHIM
  chmod +x "$TESTTMP/bin/gh" "$TESTTMP/bin/gt"
}
make_shims

# The helper resolves the repo from the working directory.
cd "$WORK" || exit 1

# ── Runners ──────────────────────────────────────────────────────────────────

# Runs the helper bounded, captures stdout, and evals it into fresh
# BASE/REF/SOURCE/PR/DEFAULT/ANCESTOR/NOTES variables. Returns the helper's
# exit status (124 if run_bounded had to kill it). Callers pass the full
# command tail: env assignments first, then `bash "$BIN"` and any arguments.
resolve() {  # resolve [VAR=value ...] bash "$BIN" [--parent <ref>]
  local out rc=0
  BASE='' REF='' SOURCE='' PR='' DEFAULT='' ANCESTOR='' NOTES=''
  out=$(run_bounded 10 env PATH="$SHIM_PATH" "$@") || rc=$?
  [ -n "$out" ] && eval "$out"
  return "$rc"
}

# True when the last resolve()'s NOTES contains the given substring.
notes_contain() {
  case "$NOTES" in
    *"$1"*) return 0 ;;
    *) return 1 ;;
  esac
}

# Runs the helper directly and captures only its stderr into $ERR. Direct
# because run_bounded discards stderr; the helper bounds its own gh/gt calls,
# so these invocations cannot block on the shims.
ERR="$TESTTMP/stderr"
helper_stderr() {  # helper_stderr [VAR=value ...] bash "$BIN" [--parent <ref>]
  env PATH="$SHIM_PATH" "$@" >/dev/null 2>"$ERR" || true
}

# ── Test: no PR, no gt parent, no config → default branch ───────────────────

rc=0; resolve bash "$BIN" || rc=$?
assert "default fallback exits 0" test "$rc" -eq 0
assert "default fallback: BASE is the default branch" test "$BASE" = main
assert "default fallback: REF prefers the remote-tracking ref" test "$REF" = origin/main
assert "default fallback: SOURCE" test "$SOURCE" = default
assert "default fallback: PR is empty" test -z "$PR"
assert "default fallback: DEFAULT" test "$DEFAULT" = main
assert "default fallback: origin/main is an ancestor of HEAD" test "$ANCESTOR" = yes
assert "default fallback: NOTES is empty" test -z "$NOTES"

# ── Test: the open PR's baseRefName wins (the incident signal) ───────────────

rc=0; resolve GH_TSV=$'parent\t42' bash "$BIN" || rc=$?
assert "PR tier exits 0" test "$rc" -eq 0
assert "PR tier: SOURCE" test "$SOURCE" = pr
assert "PR tier: BASE is bare" test "$BASE" = parent
assert "PR tier: REF is the remote-tracking ref" test "$REF" = origin/parent
assert "PR tier: PR carries the number" test "$PR" = 42
assert "PR tier: DEFAULT still reports the default branch" test "$DEFAULT" = main
assert "PR tier: parent tip is an ancestor of HEAD" test "$ANCESTOR" = yes
assert "PR tier: NOTES is empty on a clean resolution" test -z "$NOTES"

helper_stderr GH_TSV=$'parent\t42' bash "$BIN"
assert "PR tier: resolution note on stderr names the base" grep -q parent "$ERR"

# ── Test: a PR targeting the default branch stays SOURCE=pr ─────────────────

rc=0; resolve GH_TSV=$'main\t43' bash "$BIN" || rc=$?
assert "PR-to-default exits 0" test "$rc" -eq 0
assert "PR-to-default: SOURCE stays pr" test "$SOURCE" = pr
assert "PR-to-default: BASE is the default branch" test "$BASE" = main
assert "PR-to-default: PR carries the number" test "$PR" = 43
assert "PR-to-default: callers compute stacked=false" test "$BASE" = "$DEFAULT"

# ── Test: PR base with no local ref falls through with a fetch hint ─────────

rc=0; resolve GH_TSV=$'nosuchbase\t44' bash "$BIN" || rc=$?
assert "unresolvable PR base exits 0" test "$rc" -eq 0
assert "unresolvable PR base falls through to default" test "$SOURCE" = default
assert "unresolvable PR base: BASE is the default branch" test "$BASE" = main
assert "unresolvable PR base: PR stays empty" test -z "$PR"
assert "unresolvable PR base: NOTES carries the fetch hint" notes_contain 'fetch origin nosuchbase'

helper_stderr GH_TSV=$'nosuchbase\t44' bash "$BIN"
assert "unresolvable PR base: fetch hint on stderr" grep -q 'fetch origin nosuchbase' "$ERR"

# ── Test: gh failing warns; gh absent is silent ──────────────────────────────

rc=0; resolve GH_RC=1 bash "$BIN" || rc=$?
assert "failing gh exits 0" test "$rc" -eq 0
assert "failing gh degrades to default" test "$SOURCE" = default
assert "failing gh: NOTES carries the warning" notes_contain 'could not check GitHub'

rm -f "$TESTTMP/bin/gh" "$TESTTMP/bin/gt"
rc=0; resolve bash "$BIN" || rc=$?
assert "absent gh/gt exits 0" test "$rc" -eq 0
assert "absent gh/gt resolves to default" test "$SOURCE" = default
assert "absent gh/gt: NOTES is empty" test -z "$NOTES"

helper_stderr bash "$BIN"
assert "absent gh/gt stays silent on stderr" test ! -s "$ERR"
make_shims

# ── Test: gt parent tier ─────────────────────────────────────────────────────

rc=0; resolve GT_PARENT=parent bash "$BIN" || rc=$?
assert "gt tier exits 0" test "$rc" -eq 0
assert "gt tier: SOURCE" test "$SOURCE" = graphite
assert "gt tier: BASE is bare" test "$BASE" = parent
assert "gt tier: REF is the remote-tracking ref" test "$REF" = origin/parent
assert "gt tier: PR is empty" test -z "$PR"
assert "gt tier: parent tip is an ancestor of HEAD" test "$ANCESTOR" = yes

# ── Test: gt reporting the branch as its own parent is rejected ──────────────

rc=0; resolve GT_PARENT=child bash "$BIN" || rc=$?
assert "gt self-parent exits 0" test "$rc" -eq 0
assert "gt self-parent falls through to default" test "$SOURCE" = default
assert "gt self-parent: NOTES records the rejection" notes_contain 'it is the current branch'

# ── Test: gt output that is not a branch name is discarded silently ──────────

rc=0; resolve GT_PARENT='Graphite has not been initialized, attempting to set up now... Welcome to Graphite!' bash "$BIN" || rc=$?
assert "gt prose output exits 0" test "$rc" -eq 0
assert "gt prose output falls through to default" test "$SOURCE" = default
assert "gt prose output: NOTES stays empty" test -z "$NOTES"

# ── Test: a hung gt is a degradation worth a note ─────────────────────────────

rc=0; resolve GIT_PR_BASE_TIMEOUT=1 GT_SLEEP=3 bash "$BIN" || rc=$?
assert "hung gt exits 0" test "$rc" -eq 0
assert "hung gt degrades to default" test "$SOURCE" = default
assert "hung gt: NOTES carries the timeout warning" notes_contain "'gt parent' timed out"

# ── Test: git config branch.<name>.parent tier ───────────────────────────────

rm -f "$TESTTMP/bin/gt"   # gt absent: the candidate must come from config
git config branch.child.parent parent

rc=0; resolve bash "$BIN" || rc=$?
assert "config tier exits 0" test "$rc" -eq 0
assert "config tier: SOURCE" test "$SOURCE" = config
assert "config tier: BASE is bare" test "$BASE" = parent
assert "config tier: REF is the remote-tracking ref" test "$REF" = origin/parent
git config --unset branch.child.parent

# ── Test: origin/-prefixed candidates vet by their bare name ─────────────────

git config branch.child.parent origin/parent
rc=0; resolve bash "$BIN" || rc=$?
assert "origin-prefixed parent is accepted" test "$SOURCE" = config
assert "origin-prefixed parent: BASE is bare" test "$BASE" = parent
assert "origin-prefixed parent: REF" test "$REF" = origin/parent
git config --unset branch.child.parent

git config branch.child.parent origin/child
rc=0; resolve bash "$BIN" || rc=$?
assert "origin-prefixed self-parent is rejected" test "$SOURCE" = default
assert "origin-prefixed self-parent: NOTES records the rejection" notes_contain 'it is the current branch'
git config --unset branch.child.parent

# ── Test: rewritten parent (merge-base collapses to the default's) ───────────

# A "rewritten" parent shares no history with child beyond origin/main's tip,
# so merge-base(HEAD, it) equals merge-base(HEAD, origin/main) and the
# candidate must be rejected as not narrowing.
git checkout -q -b rewritten-parent origin/main
echo r1 > r1
git add r1
git commit -qm r1
git checkout -q child
git config branch.child.parent rewritten-parent

rc=0; resolve bash "$BIN" || rc=$?
assert "rewritten parent exits 0" test "$rc" -eq 0
assert "rewritten parent is rejected: SOURCE=default" test "$SOURCE" = default
assert "rewritten parent is rejected: BASE is the default branch" test "$BASE" = main
assert "rewritten parent: NOTES records the rejection" notes_contain 'does not narrow'
git config --unset branch.child.parent

# ── Test: parent forked from older trunk (wider than trunk) ──────────────────

# merge-base(HEAD, stale-fork) = m1 sits behind merge-base(HEAD, origin/main)
# = m2: the merge-bases differ, so a bare equality check would accept it, yet
# the candidate widens the range to include trunk commits.
git branch stale-fork "$M1_SHA"
git config branch.child.parent stale-fork

rc=0; resolve bash "$BIN" || rc=$?
assert "older-trunk fork exits 0" test "$rc" -eq 0
assert "older-trunk fork is rejected: SOURCE=default" test "$SOURCE" = default
assert "older-trunk fork: NOTES records the rejection" notes_contain 'does not narrow'
git config --unset branch.child.parent
make_shims

# ── Test: parent advanced beyond the fork point → accepted, ANCESTOR=no ──────

# New commit on the upstream parent (review feedback the child has not rebased
# onto): tip-ancestry now fails, but the merge-base still strictly narrows, so
# the candidate must be accepted and the fact reported via ANCESTOR.
git -C "$UPSTREAM" checkout -q parent
up_commit p3
git -C "$UPSTREAM" checkout -q main
git fetch -q origin

rc=0; resolve GT_PARENT=parent bash "$BIN" || rc=$?
assert "advanced parent exits 0" test "$rc" -eq 0
assert "advanced parent is still accepted" test "$SOURCE" = graphite
assert "advanced parent: BASE" test "$BASE" = parent
assert "advanced parent: REF" test "$REF" = origin/parent
assert "advanced parent: tip is no longer an ancestor" test "$ANCESTOR" = no
assert "advanced parent: NOTES flags the non-ancestor base" notes_contain 'not an ancestor'

# ── Test: --parent override ───────────────────────────────────────────────────

# The override outranks an available PR answer.
rc=0; resolve GH_TSV=$'main\t45' bash "$BIN" --parent origin/parent || rc=$?
assert "override exits 0" test "$rc" -eq 0
assert "override beats the PR tier" test "$SOURCE" = override
assert "override: BASE is bare" test "$BASE" = parent
assert "override: REF keeps the remote-tracking form" test "$REF" = origin/parent
assert "override: PR is empty" test -z "$PR"

# A bare spelling that names an existing local branch stays local, even when a
# remote-tracking ref of the same name exists.
git branch parent origin/parent~1
rc=0; resolve bash "$BIN" --parent parent || rc=$?
assert "local-branch override exits 0" test "$rc" -eq 0
assert "local-branch override is honored as spelled" test "$REF" = parent
assert "local-branch override: BASE" test "$BASE" = parent
git branch -D parent >/dev/null

# Unresolvable override: exit 1 with empty stdout, so eval'ing it is a no-op.
rc=0
out=$(run_bounded 10 env PATH="$SHIM_PATH" bash "$BIN" --parent nonexistent) || rc=$?
assert "unresolvable override exits 1" test "$rc" -eq 1
assert "unresolvable override prints nothing" test -z "$out"

# A non-narrowing override is honored (the human said so), with a note.
rc=0; resolve bash "$BIN" --parent stale-fork || rc=$?
assert "non-narrowing override exits 0" test "$rc" -eq 0
assert "non-narrowing override is honored" test "$SOURCE" = override
assert "non-narrowing override: BASE" test "$BASE" = stale-fork
assert "non-narrowing override: NOTES stays empty (explicit override)" test -z "$NOTES"

helper_stderr bash "$BIN" --parent stale-fork
assert "non-narrowing override: note on stderr" grep -q proceeding "$ERR"

# ── Test: detached HEAD skips every branch-keyed tier ─────────────────────────

git checkout -q --detach
rc=0; resolve GH_TSV=$'parent\t99' GT_PARENT=parent bash "$BIN" || rc=$?
assert "detached HEAD exits 0" test "$rc" -eq 0
assert "detached HEAD ignores PR and gt answers" test "$SOURCE" = default
assert "detached HEAD: BASE is the default branch" test "$BASE" = main
git checkout -q child

# ── Test: stdout is exactly the seven contract keys, in order ────────────────

# On a stacked resolution the notes go to stderr and NOTES; stdout must stay
# exactly the seven eval-safe assignments.
out=$(run_bounded 10 env PATH="$SHIM_PATH" GH_TSV=$'parent\t42' bash "$BIN") || true
assert "stdout has exactly seven lines" \
  test "$(printf '%s\n' "$out" | wc -l | tr -d '[:space:]')" -eq 7
assert "stdout keys and order match the contract" \
  test "$(printf '%s\n' "$out" | cut -d= -f1 | paste -sd, -)" = "BASE,REF,SOURCE,PR,DEFAULT,ANCESTOR,NOTES"

# ── Test: GIT_PR_BASE_TIMEOUT bounds a hung gh ───────────────────────────────

rc=0; resolve GIT_PR_BASE_TIMEOUT=1 GH_SLEEP=3 bash "$BIN" || rc=$?
assert "hung gh exits 0" test "$rc" -eq 0
assert "hung gh degrades to default" test "$SOURCE" = default
assert "hung gh: NOTES carries the warning" notes_contain 'could not check GitHub'

# ── Results ──────────────────────────────────────────────────────────────────

print_results
