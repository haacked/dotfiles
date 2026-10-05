#!/bin/bash
# Tests for git-pr: resolving a PR URL from a detached HEAD or a branch.
#
# Usage: test-git-pr.sh
#
# Builds a throwaway repo with a github.com origin and drives git-pr as a
# subprocess. The gh calls hit a PATH shim whose answers come from env vars
# (GH_API_JSON for the commits/pulls endpoint, GH_LIST_JSON and GH_LIST_FAIL for
# `gh pr list`, GH_VIEW_RC and GH_VIEW_ERR for `gh pr view`), so every case is
# offline. The controlled PATH keeps system git visible and the real gh
# invisible. The shim appends each subcommand and its first argument to $CALLS
# so a test can assert a path was never taken. Cleans up on exit.

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
# main is the pushed default branch. haacked/topic was pushed without -u.
# Only its remote-tracking ref shows that it was pushed.
git -C "$WORK" update-ref refs/remotes/origin/main HEAD
git -C "$WORK" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
git -C "$WORK" config branch.main.remote origin
git -C "$WORK" config branch.main.merge refs/heads/main
git -C "$WORK" branch haacked/topic
git -C "$WORK" update-ref refs/remotes/origin/haacked/topic HEAD

HEAD_SHA=$(git -C "$WORK" rev-parse HEAD)

SHIM_PATH="$TESTTMP/bin:/usr/bin:/bin"
# git-pr lowercases the remote owner with ${owner,,}, which needs bash 4.
find_bash4
mkdir -p "$TESTTMP/bin"
cat > "$TESTTMP/bin/gh" <<'SHIM'
#!/bin/bash
echo "$1 $2 ${3-}" >> "$CALLS"
if [ "$1" = api ]; then
    printf '%s' "${GH_API_JSON-[]}" | jq -r "${4-.}"
    exit 0
fi
if [ "$1 $2" = "pr list" ]; then
    # GH_LIST_FAIL=comments fails only a lookup whose --json fields include
    # comments. GH_LIST_FAIL=all fails every lookup.
    prev= fields=
    for arg; do [ "$prev" = --json ] && fields=$arg; prev=$arg; done
    case "${GH_LIST_FAIL-}:$fields" in
        all:* | comments:*comments*) echo "HTTP 502: 502 Bad Gateway" >&2; exit 1 ;;
    esac
    # Like gh, the response holds only the fields that --json names.
    printf '%s' "${GH_LIST_JSON-[]}" \
        | jq -c --arg fields "$fields" \
            'map(with_entries(select(.key as $k | $fields | split(",") | index($k))))' \
        | jq -r "${!#}"
    exit 0
fi
rc=${GH_VIEW_RC:-1}
[ "$rc" -eq 0 ] || echo "${GH_VIEW_ERR-no pull requests found for branch 'main'}" >&2
exit "$rc"
SHIM
chmod +x "$TESTTMP/bin/gh"

cd "$WORK" || exit 1

# A pyenv python3 shim costs about 0.2s per call.
# PYTHON is the interpreter that the shim resolves to.
PYTHON=$(python3 -c 'import sys; print(sys.executable)')

# Runs a command with its stdout on a pseudo-terminal and copies what it wrote
# to this function's stdout. The command's stderr stays this function's stderr.
# The terminal turns each newline into CRLF. The function drops the carriage
# returns.
on_tty() { # on_tty <command> [<arg> ...]
    "$PYTHON" -c '
import os, pty, sys
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.close(master)
    os.dup2(slave, 1)
    os.execvp(sys.argv[1], sys.argv[1:])
os.close(slave)
out = b""
while True:
    try:
        data = os.read(master, 4096)
    except OSError:
        break
    if not data:
        break
    out += data
_, status = os.waitpid(pid, 0)
sys.stdout.buffer.write(out)
sys.exit(os.waitstatus_to_exitcode(status))
' "$@" | tr -d '\r'
}

# Runs git-pr with the shim on PATH, capturing stdout into $OUT, stderr into
# $ERR, and the exit status into $RC. With --tty, git-pr's stdout is a terminal.
# A terminal makes git-pr print the PR's status after the URL. Settings before
# `--` go into git-pr's environment. Arguments after `--` go to git-pr. Truncates the call
# log first so each case asserts its own.
run_git_pr() { # run_git_pr [--tty] [VAR=value ...] [-- <git-pr args>]
    local cmd=(env PATH="$SHIM_PATH" CALLS="$CALLS")
    if [ "${1-}" = --tty ]; then cmd=(on_tty "${cmd[@]}"); shift; fi
    while [ $# -gt 0 ] && [ "$1" != -- ]; do cmd+=("$1"); shift; done
    [ $# -eq 0 ] || shift
    : > "$CALLS"
    RC=0
    OUT=$("${cmd[@]}" "$BASH4" "$BIN" "$@" 2>"$TESTTMP/err") || RC=$?
    ERR=$(cat "$TESTTMP/err")
}

URL9=https://github.com/haacked/dotfiles/pull/9

# A `gh pr list` response holding one approved PR at $URL9 with the given
# state. Each remaining argument becomes a comment body by trunk-io.
list_json() { # list_json <state> [<comment body> ...]
    jq -n -c --arg state "$1" --arg url "$URL9" '[{
        url: $url, state: $state,
        isDraft: false, reviewDecision: "APPROVED", latestReviews: [],
        headRepositoryOwner: {login: "haacked"},
        comments: [$ARGS.positional[] | {author: {login: "trunk-io"}, body: .}]
    }]' --args "${@:2}"
}

TRUNK_CONTROL='<!-- Trunk Merge -->
Merging to `master` in this repository is managed by Trunk.'
TRUNK_ANALYTICS='<!-- Trunk Test Analytics -->'
TRUNK_SUBMITTED='✨ Submitted to Merge by Phil Haack (@haacked). It will be added to the merge queue once all branch protection rules pass. See more details [here](https://app.trunk.io/x).'
TRUNK_STACK_SUBMITTED='✨ Stack submitted to Merge by Phil Haack (@haacked). It will be added to the merge queue once all branch protection rules pass. See more details [here](https://app.trunk.io/x).'
TRUNK_WAITING='⏳ Stack waiting to start tests on this stack because a batch ([#106996](https://www.github.com/haacked/dotfiles/pull/106996)) ahead of it failed tests - [details](https://app.trunk.io/x).'
TRUNK_TESTING='🧪 Running tests on this stack (testing on PR [#12](https://www.github.com/haacked/dotfiles/pull/12)) - [details](https://app.trunk.io/x).'
TRUNK_PASSED='👍 Pull request will be merged soon because it has passed required tests (tested on PR [#12](https://www.github.com/haacked/dotfiles/pull/12)) - [details](https://app.trunk.io/x).'
TRUNK_FAILED='❌ This pull request was removed from the merge queue because it failed tests. PR [#12](https://github.com/haacked/dotfiles/pull/12) was used for testing. See more details [here](https://app.trunk.io/x).'
TRUNK_STALE_TIMEOUT='🚫 This pull request was removed from the merge queue because it was waiting to become mergeable for too long (for example: missing required approvals or checks, or a merge conflict). Submit it again once it is ready.'
TRUNK_ERROR='An error occurred while submitting your PR to the queue: `Something went wrong. Please try again`'
TRUNK_MERGED='😎 Merged successfully - [details](https://app.trunk.io/x).'

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
assert_not "a non-matching head.sha never calls gh pr view" grep -q 'pr view' "$CALLS"
assert "a non-matching head.sha reports No PR" test "$ERR" = "No PR"

# ── Test: an open PR outranks a closed one ──────────────────────────────────

BOTH=$(jq -n -c --arg sha "$HEAD_SHA" \
    '[{head: {sha: $sha, ref: "a"}, state: "closed", html_url: "https://github.com/haacked/dotfiles/pull/1"},
      {head: {sha: $sha, ref: "b"}, state: "open", html_url: "https://github.com/haacked/dotfiles/pull/2"}]')
run_git_pr GH_API_JSON="$BOTH"
assert "an open PR outranks a closed one" test "$OUT" = https://github.com/haacked/dotfiles/pull/2

# ── Test: no associated PR reports No PR ────────────────────────────────────

run_git_pr GH_API_JSON='[]'
assert "no associated PR exits non-zero" test "$RC" -ne 0
assert_not "no associated PR never calls gh pr view" grep -q 'pr view' "$CALLS"
assert "no associated PR reports No PR" test "$ERR" = "No PR"

# ── Test: an explicit PR that gh cannot find reports No PR ──────────────────

run_git_pr GH_VIEW_ERR='GraphQL: Could not resolve to a PullRequest with the number of 123.' -- 123
assert "a missing explicit PR exits non-zero" test "$RC" -ne 0
assert "a missing explicit PR reports No PR" test "$ERR" = "No PR"

# ── Test: a gh failure other than not-found keeps gh's message ──────────────

run_git_pr GH_VIEW_ERR='HTTP 401: Bad credentials' -- 123
assert "an auth failure exits non-zero" test "$RC" -ne 0
assert "an auth failure prints gh's error instead of No PR" test "$ERR" = 'HTTP 401: Bad credentials'

# ── Test: an attached branch never queries the commit endpoint ──────────────

git checkout -q haacked/topic
run_git_pr GH_API_JSON="$(pull_json "$HEAD_SHA" open https://github.com/haacked/dotfiles/pull/7)"
assert "an attached branch looks the PR up by branch" grep -q '^pr list' "$CALLS"
assert_not "an attached branch never calls gh api" grep -q '^api' "$CALLS"

# ── Test: a branch PR prints a bare URL when stdout is not a terminal ───────

run_git_pr GH_LIST_JSON='[{"url":"https://github.com/haacked/dotfiles/pull/9","state":"OPEN","headRepositoryOwner":{"login":"haacked"}}]'
assert "a branch PR exits 0" test "$RC" -eq 0
assert "a branch PR prints only the URL when piped" test "$OUT" = https://github.com/haacked/dotfiles/pull/9

# ── Test: a branch without a PR reports No PR ────────────────────────────────

run_git_pr GH_LIST_JSON='[]'
assert "a branch without a PR exits non-zero" test "$RC" -ne 0
assert "a branch without a PR prints nothing on stdout" test -z "$OUT"
assert "a branch without a PR reports No PR" test "$ERR" = "No PR"

# ── Test: branches that cannot have a PR skip the lookup ────────────────────

assert_no_lookup() { # assert_no_lookup <description> [<git-pr arg> ...]
    run_git_pr GH_LIST_JSON="$(list_json OPEN)" -- "${@:2}"
    assert "$1 reports No PR" test "$ERR" = "No PR"
    assert "$1 exits non-zero" test "$RC" -ne 0
    assert "$1 never calls gh" test ! -s "$CALLS"
}

git checkout -q main
assert_no_lookup "the default branch"

git checkout -q -b from-main
git config branch.from-main.remote origin
git config branch.from-main.merge refs/heads/main
assert_no_lookup "a branch whose upstream is the default branch"

git checkout -q -b never-pushed
assert_no_lookup "a branch that was never pushed"

# ── Test: --include-default-prs looks the default branch up ─────────────────

assert_no_lookup "a never-pushed branch with --include-default-prs" --include-default-prs

git checkout -q main
run_git_pr GH_LIST_JSON="$(list_json OPEN)" -- --include-default-prs
assert "--include-default-prs finds a PR from the default branch" test "$OUT" = "$URL9"

run_git_pr -- --include-default-prs 123
assert "--include-default-prs with a number only views that PR" test "$(cat "$CALLS")" = "pr view 123"

# ── Test: an upstream without a remote-tracking ref still looks the PR up ───

git checkout -q -b pruned
git config branch.pruned.remote origin
git config branch.pruned.merge refs/heads/pruned
run_git_pr GH_LIST_JSON="$(list_json MERGED)"
assert "a pruned branch with an upstream finds its PR" test "$OUT" = "$URL9"

# ── Test: a fork's main checked out under another name still looks it up ────

git checkout -q -b contributor/main
git config branch.contributor/main.remote git@github.com:contributor/dotfiles.git
git config branch.contributor/main.merge refs/heads/main
run_git_pr GH_LIST_JSON='[{"url":"https://github.com/haacked/dotfiles/pull/10","state":"OPEN","headRepositoryOwner":{"login":"contributor"}}]'
assert "a fork PR from main finds its PR" test "$OUT" = https://github.com/haacked/dotfiles/pull/10

git checkout -q haacked/topic

# ── Test: a terminal shows the review status ────────────────────────────────

run_git_pr --tty GH_LIST_JSON="$(list_json OPEN)"
assert "a terminal exits 0" test "$RC" -eq 0
assert "a terminal shows the review status" test "$OUT" = "$URL9 (Approved)"

# ── Test: Trunk comments that name no queue state add nothing ───────────────

run_git_pr --tty GH_LIST_JSON="$(list_json OPEN "$TRUNK_CONTROL" "$TRUNK_ANALYTICS")"
assert "an un-submitted PR shows no queue status" test "$OUT" = "$URL9 (Approved)"

run_git_pr --tty GH_LIST_JSON="$(list_json OPEN "$TRUNK_ERROR")"
assert "a lone submission error shows no queue status" test "$OUT" = "$URL9 (Approved)"

run_git_pr --tty GH_LIST_JSON="$(list_json OPEN "$TRUNK_CONTROL
$TRUNK_SUBMITTED")"
assert "a status phrase after the first line adds nothing" test "$OUT" = "$URL9 (Approved)"

# ── Test: each Trunk status maps to a queue label ───────────────────────────

assert_queue_label() { # assert_queue_label <description> <expected label> <comment body>
    run_git_pr --tty GH_LIST_JSON="$(list_json OPEN "$3")"
    assert "$1" test "$OUT" = "$URL9 (Approved, $2)"
}

assert_queue_label "a submitted PR shows Submitted" "Submitted to Trunk Queue" "$TRUNK_SUBMITTED"
assert_queue_label "a submitted stack shows Submitted" "Submitted to Trunk Queue" "$TRUNK_STACK_SUBMITTED"
assert_queue_label "a PR behind a failed batch shows Waiting" "Waiting in Trunk Queue" "$TRUNK_WAITING"
assert_queue_label "a PR under test shows Testing" "Testing in Trunk Queue" "$TRUNK_TESTING"
assert_queue_label "a PR that passed shows Passed" "Passed Trunk Queue" "$TRUNK_PASSED"
assert_queue_label "a PR that failed tests shows Removed" "Removed from Trunk Queue" "$TRUNK_FAILED"
assert_queue_label "a PR evicted while waiting shows Removed" "Removed from Trunk Queue" "$TRUNK_STALE_TIMEOUT"

# ── Test: a later submission error does not hide the status ─────────────────

run_git_pr --tty GH_LIST_JSON="$(list_json OPEN "$TRUNK_SUBMITTED" "$TRUNK_ERROR")"
assert "a later error keeps the status" test "$OUT" = "$URL9 (Approved, Submitted to Trunk Queue)"

# ── Test: only trunk-io sets the queue status ───────────────────────────────

IMPOSTOR=$(list_json OPEN | jq -c --arg body "$TRUNK_SUBMITTED" \
    '.[0].comments = [{author: {login: "someone"}, body: $body}]')
run_git_pr --tty GH_LIST_JSON="$IMPOSTOR"
assert "another author's status comment adds nothing" test "$OUT" = "$URL9 (Approved)"

# ── Test: a merged or closed PR shows no queue status ───────────────────────

run_git_pr --tty GH_LIST_JSON="$(list_json MERGED "$TRUNK_MERGED")"
assert "a merged PR shows only Merged" test "$OUT" = "$URL9 (Merged)"

run_git_pr --tty GH_LIST_JSON="$(list_json CLOSED "$TRUNK_FAILED")"
assert "a closed PR shows only Closed" test "$OUT" = "$URL9 (Closed)"

# ── Test: a failed lookup with comments retries without them ────────────────

run_git_pr --tty GH_LIST_FAIL=comments GH_LIST_JSON="$(list_json OPEN "$TRUNK_SUBMITTED")"
assert "the retry exits 0" test "$RC" -eq 0
assert "the retry shows the status without the queue status" test "$OUT" = "$URL9 (Approved)"
assert "the retry hides the first failure" test -z "$ERR"
assert "the retry looks the PR up twice" test "$(grep -c '^pr list' "$CALLS")" -eq 2

run_git_pr --tty GH_LIST_FAIL=all
assert "a failed retry exits non-zero" test "$RC" -ne 0
assert "a failed retry prints gh's error once" test "$ERR" = "HTTP 502: 502 Bad Gateway"

run_git_pr GH_LIST_FAIL=all
assert "a failed piped lookup exits non-zero" test "$RC" -ne 0
assert "a failed piped lookup never retries" test "$(grep -c '^pr list' "$CALLS")" -eq 1

# ── Test: piped output stays a bare URL on a queued PR ──────────────────────

run_git_pr GH_LIST_JSON="$(list_json OPEN "$TRUNK_SUBMITTED")"
assert "a queued PR prints only the URL when piped" test "$OUT" = "$URL9"

print_results
