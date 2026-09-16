#!/bin/bash
# Tests for git-pr: resolving a PR URL from a detached HEAD.
#
# Usage: test-git-pr.sh
#
# Builds a throwaway repo with a github.com origin and drives git-pr as a
# subprocess. The gh calls hit a PATH shim whose answers come from env vars
# (GH_API_JSON for the commits/pulls endpoint, GH_VIEW_RC for the bare
# `gh pr view` fallback), so every case is offline; the controlled PATH keeps
# system git visible and the real gh invisible. The shim appends each
# subcommand to $CALLS so a test can assert a path was never taken.
# Cleans up on exit.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

BIN="$SCRIPT_DIR/../git-pr"

# ── Fixture ──────────────────────────────────────────────────────────────────

TESTTMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TESTTMP"' EXIT

WORK="$TESTTMP/work"
CALLS="$TESTTMP/calls"

mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name "Test"
git -C "$WORK" config commit.gpgsign false
git -C "$WORK" checkout -q -b main
git -C "$WORK" remote add origin git@github.com:haacked/dotfiles.git
echo one > "$WORK/one"
git -C "$WORK" add one
git -C "$WORK" commit -qm one

HEAD_SHA=$(git -C "$WORK" rev-parse HEAD)

SHIM_PATH="$TESTTMP/bin:/usr/bin:/bin"
mkdir -p "$TESTTMP/bin"
cat > "$TESTTMP/bin/gh" <<'SHIM'
#!/bin/bash
echo "$1 $2" >> "$CALLS"
if [ "$1" = api ]; then
    printf '%s' "${GH_API_JSON-[]}" | jq -r "${4-.}"
    exit 0
fi
exit "${GH_VIEW_RC:-1}"
SHIM
chmod +x "$TESTTMP/bin/gh"

cd "$WORK" || exit 1

# Runs git-pr with the shim on PATH, capturing stdout into $OUT and the exit
# status into $RC. Truncates the call log first so each case asserts its own.
run_git_pr() { # run_git_pr [VAR=value ...]
    : > "$CALLS"
    RC=0
    OUT=$(env PATH="$SHIM_PATH" CALLS="$CALLS" "$@" bash "$BIN" 2>/dev/null) || RC=$?
}

# A commits/pulls response holding one PR.
pull_json() { # pull_json <head_sha> <state> <url>
    jq -n -c --arg sha "$1" --arg state "$2" --arg url "$3" \
        '[{head: {sha: $sha, ref: "haacked/x"}, state: $state, html_url: $url}]'
}

# ── Test: detached HEAD with a matching head.sha resolves ────────────────────

git checkout -q --detach HEAD

run_git_pr GH_API_JSON="$(pull_json "$HEAD_SHA" open https://github.com/haacked/dotfiles/pull/7)"
assert "detached HEAD exits 0 on a match" test "$RC" -eq 0
assert "detached HEAD prints the PR URL" test "$OUT" = https://github.com/haacked/dotfiles/pull/7
assert_not "detached HEAD never falls back to gh pr view" grep -q 'pr view' "$CALLS"

# ── Test: a PR the commit merged into is not this commit's PR ────────────────

run_git_pr GH_API_JSON="$(pull_json 0000000000000000000000000000000000000000 closed https://github.com/haacked/dotfiles/pull/8)"
assert "a non-matching head.sha exits non-zero" test "$RC" -ne 0
assert "a non-matching head.sha prints nothing" test -z "$OUT"
assert "a non-matching head.sha falls through to gh pr view" grep -q 'pr view' "$CALLS"

# ── Test: an open PR outranks a closed one ──────────────────────────────────

BOTH=$(jq -n -c --arg sha "$HEAD_SHA" \
    '[{head: {sha: $sha, ref: "a"}, state: "closed", html_url: "https://github.com/haacked/dotfiles/pull/1"},
      {head: {sha: $sha, ref: "b"}, state: "open", html_url: "https://github.com/haacked/dotfiles/pull/2"}]')
run_git_pr GH_API_JSON="$BOTH"
assert "an open PR outranks a closed one" test "$OUT" = https://github.com/haacked/dotfiles/pull/2

# ── Test: no associated PR keeps the existing failure ───────────────────────

run_git_pr GH_API_JSON='[]'
assert "no associated PR exits non-zero" test "$RC" -ne 0
assert "no associated PR falls through to gh pr view" grep -q 'pr view' "$CALLS"

# ── Test: an attached branch never queries the commit endpoint ──────────────

git checkout -q main
run_git_pr GH_API_JSON="$(pull_json "$HEAD_SHA" open https://github.com/haacked/dotfiles/pull/7)"
assert_not "an attached branch never calls gh api" grep -q '^api' "$CALLS"

print_results
