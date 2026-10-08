#!/bin/bash
# Tests for git-pr: resolving a PR URL from a detached HEAD or a branch, and
# showing the PR's status and stack on a terminal, or the PR as JSON with --json.
#
# Usage: test-git-pr.sh
#
# Builds a throwaway repo with a github.com origin and drives git-pr as a
# subprocess. The gh calls hit a PATH shim whose answers come from env vars
# (GH_API_JSON for the commits/pulls endpoint, GH_LIST_JSON and GH_LIST_FAIL for
# `gh pr list --state all`, GH_STACK_JSON and GH_STACK_FAIL for the stack
# lookups through `gh pr list --state open`, GH_VIEW_JSON, GH_VIEW_RC and
# GH_VIEW_ERR for `gh pr view`), so every case is offline. The controlled PATH
# keeps system git visible and the real gh invisible. The shim appends one line
# per call to $CALLS so a test can assert a path was never taken. The line holds
# every argument except the values of --json, -q, and --jq. Cleans up on exit.

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
# The values of --json, -q, and --jq hold field lists and jq programs, so the
# log leaves them out.
logged=() prev= fields= head= base= state=
for arg; do
    case $prev in
        --json) fields=$arg ;;
        -q | --jq) ;;
        *) logged+=("$arg") ;;
    esac
    case $prev in
        --head) head=$arg ;;
        --base) base=$arg ;;
        --state) state=$arg ;;
    esac
    prev=$arg
done
echo "${logged[*]}" >> "$CALLS"
bad_gateway() { echo "HTTP 502: 502 Bad Gateway" >&2; exit 1; }
# Like gh, the response holds only the fields that --json names.
keep='with_entries(select(.key as $k | $fields | split(",") | index($k)))'
if [ "$1" = api ]; then
    printf '%s' "${GH_API_JSON-[]}" | jq -r "${4-.}"
    exit 0
fi
if [ "$1 $2" = "pr list" ]; then
    if [ "$state" = open ]; then
        # GH_STACK_FAIL=children fails only a lookup for children, which names
        # --base. Any other value fails every stack lookup.
        case "${GH_STACK_FAIL-}" in
            children) [ -z "$base" ] || bad_gateway ;;
            ?*) bad_gateway ;;
        esac
        prs=$(printf '%s' "${GH_STACK_JSON-[]}" | jq -c --arg head "$head" --arg base "$base" \
            'map(select(.state == "OPEN"
                and ($head == "" or .headRefName == $head)
                and ($base == "" or .baseRefName == $base)))')
    else
        # GH_LIST_FAIL=comments fails only a lookup whose --json fields include
        # comments. GH_LIST_FAIL=all fails every lookup. Neither fails a stack
        # lookup, although its fields include comments too.
        case "${GH_LIST_FAIL-}:$fields" in
            all:* | comments:*comments*) bad_gateway ;;
        esac
        prs=${GH_LIST_JSON-[]}
    fi
    printf '%s' "$prs" | jq -c --arg fields "$fields" "map($keep)" | jq -r "${!#}"
    exit 0
fi
if [ -n "${GH_VIEW_JSON-}" ]; then
    printf '%s' "$GH_VIEW_JSON" | jq -c --arg fields "$fields" "$keep" | jq -r "${!#}"
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
# The function kills a command still running after 10 seconds and exits 124
# with no output. A hang then fails its test instead of stalling the suite.
# The command runs in its own session, so the kill also reaches the subshells it
# forked.
on_tty() { # on_tty <command> [<arg> ...]
    "$PYTHON" -c '
import os, pty, signal, sys
master, slave = pty.openpty()
pid = os.fork()
if pid == 0:
    os.setsid()
    os.close(master)
    os.dup2(slave, 1)
    os.execvp(sys.argv[1], sys.argv[1:])
os.close(slave)
def expire(signum, frame):
    try:
        os.killpg(pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    sys.exit(124)
signal.signal(signal.SIGALRM, expire)
signal.alarm(10)
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
signal.alarm(0)
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

# An open same-repo PR from <head> into <base> with every field git-pr asks
# for. <review> is the reviewDecision, or draft for a draft PR. Each remaining
# argument becomes a comment body by trunk-io.
stack_pr() { # stack_pr <number> <head> <base> [<review>] [<comment body> ...]
    jq -n -c --argjson number "$1" --arg head "$2" --arg base "$3" --arg review "${4-APPROVED}" '{
        url: "https://github.com/haacked/dotfiles/pull/\($number)", number: $number,
        state: "OPEN", isDraft: ($review == "draft"),
        reviewDecision: (if $review == "draft" then "" else $review end), reviews: [],
        headRefName: $head, baseRefName: $base, isCrossRepository: false,
        headRepositoryOwner: {login: "haacked"},
        comments: [$ARGS.positional[] | {author: {login: "trunk-io"}, body: .}]
    }' --args "${@:5}"
}

# A `gh pr list` response holding one approved PR at $URL9 from haacked/topic
# into main with the given state. Each remaining argument becomes a comment
# body by trunk-io.
list_json() { # list_json <state> [<comment body> ...]
    stack_pr 9 haacked/topic main APPROVED "${@:2}" | jq -c --arg state "$1" '[.state = $state]'
}

# Moves the head branch of the PR object on stdin into a fork.
fork() { jq -c '.isCrossRepository = true | .headRepositoryOwner.login = "contributor"'; }

prs() { jq -s -c . <<<"$*"; } # prs [<PR object> ...]

# Runs git-pr on a terminal. The first PR object is the PR of the checked-out
# branch. GH_STACK_JSON stands for every PR in the repo, so it holds all the
# objects, the current PR included.
run_stack() { # run_stack <current PR> [<PR> ...]
    run_git_pr --tty GH_LIST_JSON="[$1]" GH_STACK_JSON="$(prs "$@")"
}

stack_lookups() { grep -- '--state open' "$CALLS"; }

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
assert "--include-default-prs with a number only views that PR" test "$(cut -d ' ' -f 1-3 "$CALLS")" = "pr view 123"

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

# ── Test: each review state maps to a status ────────────────────────────────

assert_review_status() { # assert_review_status <description> <expected status> <review> [<login>:<state> ...]
    local pr
    pr=$(stack_pr 9 haacked/topic main "$3" | jq -c \
        '.reviews = [$ARGS.positional[] | split(":") | {author: {login: .[0]}, state: .[1]}]' --args "${@:4}")
    run_git_pr --tty GH_LIST_JSON="[$pr]"
    assert "$1" test "$OUT" = "$URL9 ($2)"
}

assert_review_status "a PR that needs a review shows Review required" "Review required" REVIEW_REQUIRED
assert_review_status "a PR with changes requested shows Changes requested" "Changes requested" CHANGES_REQUESTED
assert_review_status "a draft PR shows Draft" Draft draft
assert_review_status "a PR without a decision or reviews shows Not approved" "Not approved" ''
assert_review_status "a PR without a decision and only comments shows Not approved" "Not approved" '' \
    bot:COMMENTED
assert_review_status "a PR without a decision and an approval shows Approved" Approved '' alice:APPROVED
assert_review_status "a PR without a decision and a change request shows Changes requested" \
    "Changes requested" '' alice:CHANGES_REQUESTED
assert_review_status "a PR without a decision shows a change request over an approval" \
    "Changes requested" '' alice:APPROVED bob:CHANGES_REQUESTED
# GitHub lists a PR's reviews oldest first.
assert_review_status "a comment after an approval keeps the approval" Approved '' \
    alice:APPROVED alice:COMMENTED
assert_review_status "a comment after a change request keeps the change request" "Changes requested" '' \
    alice:CHANGES_REQUESTED alice:COMMENTED
assert_review_status "an approval after a change request replaces it" Approved '' \
    alice:CHANGES_REQUESTED alice:APPROVED
assert_review_status "a pending review after an approval keeps the approval" Approved '' \
    alice:APPROVED alice:PENDING
assert_review_status "a dismissed review after an approval replaces it" "Not approved" '' \
    alice:APPROVED alice:DISMISSED

run_git_pr --tty GH_LIST_JSON="[$(stack_pr 9 haacked/topic main REVIEW_REQUIRED "$TRUNK_SUBMITTED")]"
assert "a queued PR that needs a review shows both statuses" \
    test "$OUT" = "$URL9 (Review required, Submitted to Trunk Queue)"

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
assert "the retry looks the PR up twice" test "$(grep -c '^pr list .*--state all' "$CALLS")" -eq 2

run_git_pr --tty GH_LIST_FAIL=all
assert "a failed retry exits non-zero" test "$RC" -ne 0
assert "a failed retry prints gh's error once" test "$ERR" = "HTTP 502: 502 Bad Gateway"

run_git_pr GH_LIST_FAIL=all
assert "a failed piped lookup exits non-zero" test "$RC" -ne 0
assert "a failed piped lookup never retries" test "$(grep -c '^pr list' "$CALLS")" -eq 1

# ── Test: piped output stays a bare URL on a queued PR ──────────────────────

run_git_pr GH_LIST_JSON="$(list_json OPEN "$TRUNK_SUBMITTED")"
assert "a queued PR prints only the URL when piped" test "$OUT" = "$URL9"

# ── Test: an unstacked PR shows no stack ─────────────────────────────────────

# PR #21 comes from main. A lookup of main's PR would show it as a parent.
run_stack "$(stack_pr 9 haacked/topic main)" \
    "$(stack_pr 20 haacked/other main)" \
    "$(stack_pr 21 main haacked/release)"
assert "an unstacked PR prints only its status line" test "$OUT" = "$URL9 (Approved)"
assert "an unstacked PR looks its children up" grep -qE -- '--base haacked/topic( |$)' <(stack_lookups)
assert_not "an unstacked PR never looks up a PR from the default branch" \
    grep -qE -- '--head main( |$)' <(stack_lookups)

# ── Test: a PR stacked on another PR shows the PR below it ───────────────────

run_stack "$(stack_pr 9 haacked/topic haacked/parent)" \
    "$(stack_pr 10 haacked/parent main APPROVED "$TRUNK_TESTING")" \
    "$(stack_pr 21 main haacked/release)"
assert "a PR with a parent exits 0" test "$RC" -eq 0
assert "a PR with a parent shows the parent's status and the base branch" test "$OUT" = "$URL9 (Approved)
> #9 Approved
  #10 Approved, Testing in Trunk Queue
  main"
assert_not "the walk down stops at the default branch" grep -qE -- '--head main( |$)' <(stack_lookups)
assert_not "no stack lookup omits the PR's repo" \
    grep -vqE -- '--repo github.com/haacked/dotfiles( |$)' <(stack_lookups)

# ── Test: a PR with a child shows the child above it ─────────────────────────

run_stack "$(stack_pr 9 haacked/topic main)" \
    "$(stack_pr 11 haacked/child haacked/topic REVIEW_REQUIRED)"
assert "a PR with a child shows the child above it" test "$OUT" = "$URL9 (Approved)
  #11 Review required
> #9 Approved
  main"

# ── Test: a PR mid-stack shows every PR above and below it ───────────────────

run_stack "$(stack_pr 9 haacked/topic haacked/b)" \
    "$(stack_pr 11 haacked/d haacked/c REVIEW_REQUIRED)" \
    "$(stack_pr 7 haacked/a main APPROVED "$TRUNK_TESTING")" \
    "$(stack_pr 10 haacked/c haacked/topic draft)" \
    "$(stack_pr 20 haacked/other main)" \
    "$(stack_pr 8 haacked/b haacked/a CHANGES_REQUESTED)"
assert "a mid-stack PR shows two levels each way" test "$OUT" = "$URL9 (Approved)
  #11 Review required
  #10 Draft
> #9 Approved
  #8 Changes requested
  #7 Approved, Testing in Trunk Queue
  main"

# ── Test: sibling children mark the PR they sit on ───────────────────────────

URL12=https://github.com/haacked/dotfiles/pull/12
run_stack "$(stack_pr 12 haacked/topic main)" \
    "$(stack_pr 13 haacked/thirteen haacked/topic REVIEW_REQUIRED)" \
    "$(stack_pr 14 haacked/fourteen haacked/topic draft)" \
    "$(stack_pr 15 haacked/fifteen haacked/thirteen REVIEW_REQUIRED)"
assert "a PR whose base PR is not the line below names its base" test "$OUT" = "$URL12 (Approved)
  #15 Review required
  #13 Review required (on #12)
  #14 Draft
> #12 Approved
  main"

# ── Test: a fork's PR from a branch named like the base is not the parent ────

run_stack "$(stack_pr 9 haacked/topic haacked/parent)" \
    "$(stack_pr 30 haacked/parent main | fork)" \
    "$(stack_pr 11 haacked/child haacked/topic REVIEW_REQUIRED)"
assert "a fork's same-named PR leaves the base branch at the bottom" test "$OUT" = "$URL9 (Approved)
  #11 Review required
> #9 Approved
  haacked/parent"

run_stack "$(stack_pr 9 haacked/topic haacked/parent)" \
    "$(stack_pr 30 haacked/parent main | fork)" \
    "$(stack_pr 10 haacked/parent main)"
assert "a same-repo parent outranks a fork's same-named PR listed first" test "$OUT" = "$URL9 (Approved)
> #9 Approved
  #10 Approved
  main"

# ── Test: a base branch without an open PR ends the stack ────────────────────

run_stack "$(stack_pr 9 haacked/topic haacked/gone)" \
    "$(stack_pr 5 haacked/gone main | jq -c '.state = "MERGED"')"
assert "a PR on a branch whose PR merged, with no children, shows no stack" \
    test "$OUT" = "$URL9 (Approved)"

run_stack "$(stack_pr 9 haacked/topic haacked/gone)" \
    "$(stack_pr 11 haacked/child haacked/topic REVIEW_REQUIRED)"
assert "a stack over a branch without an open PR ends at that branch" test "$OUT" = "$URL9 (Approved)
  #11 Review required
> #9 Approved
  haacked/gone"

# ── Test: a PR from a fork never looks its children up ───────────────────────

# The fork's branch is named main. The base repo's PRs into main are not its
# children.
git checkout -q contributor/main
run_stack "$(stack_pr 31 main haacked/parent | fork)" \
    "$(stack_pr 10 haacked/parent main)" \
    "$(stack_pr 20 haacked/other main)"
assert "a fork's PR still shows the PRs below it" test "$OUT" = "https://github.com/haacked/dotfiles/pull/31 (Approved)
> #31 Approved
  #10 Approved
  main"
assert_not "a fork's PR never looks its children up" grep -q -- '--base ' <(stack_lookups)
git checkout -q haacked/topic

# PR #33 targets a same-repo branch named like the fork's branch of PR #32.
run_stack "$(stack_pr 9 haacked/topic main)" \
    "$(stack_pr 32 patch-1 haacked/topic REVIEW_REQUIRED | fork)" \
    "$(stack_pr 33 haacked/x patch-1)"
assert "a child from a fork is listed without its own children" test "$OUT" = "$URL9 (Approved)
  #32 Review required
> #9 Approved
  main"
assert_not "a child from a fork never has its children looked up" \
    grep -qE -- '--base patch-1( |$)' <(stack_lookups)

# ── Test: piped output never looks the stack up ──────────────────────────────

# PR #9 sits between a parent and a child. Later sections reuse these PRs.
ON_PARENT=$(stack_pr 9 haacked/topic haacked/parent)
PARENT=$(stack_pr 10 haacked/parent main)
CHILD=$(stack_pr 11 haacked/child haacked/topic REVIEW_REQUIRED)
STACK=$(prs "$ON_PARENT" "$PARENT" "$CHILD")

run_git_pr GH_LIST_JSON="[$ON_PARENT]" GH_STACK_JSON="$STACK"
assert "a stacked PR prints only the URL when piped" test "$OUT" = "$URL9"
assert_not "piped output never looks the stack up" grep -q -- '--state open' "$CALLS"

# ── Test: --json prints the PR as one JSON object ────────────────────────────

# The object that --json prints for PR #9 from haacked/topic, compact with
# sorted keys.
pr9_json() { # pr9_json <state> <base> <status>
    jq -n -c -S --arg url "$URL9" --arg state "$1" --arg base "$2" --arg status "$3" \
        '{url: $url, number: 9, state: $state, head: "haacked/topic", base: $base, status: $status}'
}

# $OUT compact with sorted keys. Output that is not JSON prints nothing.
# jq colors its output on a terminal, so the color codes are removed first.
json_out() { perl -pe 's/\e\[[0-9;]*m//g' <<<"$OUT" | jq -c -S . 2>/dev/null; }

OPEN_INTO_MAIN=$(pr9_json OPEN main Approved)

run_git_pr GH_LIST_JSON="$(list_json OPEN "$TRUNK_SUBMITTED")" -- --json
assert "--json exits 0" test "$RC" -eq 0
assert "--json prints an open PR with an integer number and its full status (got '$OUT')" \
    test "$(json_out)" = "$(pr9_json OPEN main "Approved, Submitted to Trunk Queue")"

run_git_pr GH_LIST_JSON="$(list_json MERGED "$TRUNK_MERGED")" -- --json
assert "--json prints a merged PR's state and status (got '$OUT')" \
    test "$(json_out)" = "$(pr9_json MERGED main Merged)"

# ── Test: --json never looks the stack up ────────────────────────────────────

run_git_pr GH_LIST_JSON="[$ON_PARENT]" GH_STACK_JSON="$STACK" -- --json
assert "--json prints a stacked PR's base branch (got '$OUT')" \
    test "$(json_out)" = "$(pr9_json OPEN haacked/parent Approved)"
assert_not "--json never looks the stack up" grep -q -- '--state open' "$CALLS"

run_git_pr --tty GH_LIST_JSON="[$ON_PARENT]" GH_STACK_JSON="$STACK" -- --json
assert "--json on a terminal prints the object instead of the stack (got '$OUT')" \
    test "$(json_out)" = "$(pr9_json OPEN haacked/parent Approved)"
assert_not "--json on a terminal never looks the stack up" grep -q -- '--state open' "$CALLS"

# ── Test: --json retries a failed lookup without comments ────────────────────

run_git_pr GH_LIST_FAIL=comments GH_LIST_JSON="$(list_json OPEN "$TRUNK_SUBMITTED")" -- --json
assert "--json's retry prints the status without the queue status (got '$OUT')" \
    test "$(json_out)" = "$OPEN_INTO_MAIN"
assert "--json's retry looks the PR up twice" \
    test "$(grep -c '^pr list .*--state all' "$CALLS")" -eq 2

# ── Test: --json without a PR prints nothing ─────────────────────────────────

run_git_pr GH_LIST_JSON='[]' -- --json
assert "--json without a PR exits non-zero" test "$RC" -ne 0
assert "--json without a PR prints nothing on stdout" test -z "$OUT"
assert "--json without a PR reports No PR" test "$ERR" = "No PR"

# ── Test: --json with an explicit PR prints that PR ──────────────────────────

run_git_pr GH_VIEW_JSON="$(stack_pr 9 haacked/topic main)" -- --json 9
assert "--json before a PR number prints that PR (got '$OUT')" test "$(json_out)" = "$OPEN_INTO_MAIN"
assert "--json is not passed to gh as the PR" grep -q '^pr view 9 ' "$CALLS"

# ── Test: --json on a detached HEAD looks the PR up again ────────────────────

git checkout -q --detach HEAD
run_git_pr GH_API_JSON="$(pull_json "$HEAD_SHA" open "$URL9")" \
    GH_VIEW_JSON="$(stack_pr 9 haacked/topic main)" -- --json
git checkout -q haacked/topic
assert "--json on a detached HEAD prints the PR (got '$OUT')" test "$(json_out)" = "$OPEN_INTO_MAIN"
assert "--json on a detached HEAD views the PR for its status" grep -q "^pr view $URL9 " "$CALLS"

# ── Test: --json and --include-default-prs combine in either order ───────────

git checkout -q main
assert_no_lookup "the default branch with --json" --json

run_git_pr GH_LIST_JSON="$(list_json OPEN)" -- --include-default-prs --json
assert "--include-default-prs --json prints the PR (got '$OUT')" test "$(json_out)" = "$OPEN_INTO_MAIN"

run_git_pr GH_LIST_JSON="$(list_json OPEN)" -- --json --include-default-prs
assert "--json --include-default-prs prints the PR (got '$OUT')" test "$(json_out)" = "$OPEN_INTO_MAIN"
git checkout -q haacked/topic

# ── Test: a merged or closed PR never looks the stack up ─────────────────────

run_stack "$(jq -c '.state = "MERGED"' <<<"$ON_PARENT")" "$PARENT" "$CHILD"
assert "a merged stacked PR shows only its status line" test "$OUT" = "$URL9 (Merged)"
assert_not "a merged PR never looks the stack up" grep -q -- '--state open' "$CALLS"

run_stack "$(jq -c '.state = "CLOSED"' <<<"$ON_PARENT")" "$PARENT" "$CHILD"
assert "a closed stacked PR shows only its status line" test "$OUT" = "$URL9 (Closed)"
assert_not "a closed PR never looks the stack up" grep -q -- '--state open' "$CALLS"

# ── Test: a failed stack lookup keeps the status line ────────────────────────

run_git_pr --tty GH_STACK_FAIL=1 GH_LIST_JSON="[$ON_PARENT]" GH_STACK_JSON="$STACK"
assert "a failed stack lookup exits 0" test "$RC" -eq 0
assert "a failed stack lookup prints only the status line" test "$OUT" = "$URL9 (Approved)"
assert "a failed stack lookup reports the failure" test "$ERR" = "Stack lookup failed"

# Only the children lookup fails.
run_git_pr --tty GH_STACK_FAIL=children GH_LIST_JSON="[$ON_PARENT]" GH_STACK_JSON="$STACK"
assert "a failed children lookup exits 0" test "$RC" -eq 0
assert "a failed children lookup drops the parent too" test "$OUT" = "$URL9 (Approved)"
assert "a failed children lookup reports the failure" test "$ERR" = "Stack lookup failed"

# ── Test: a cycle of PRs ends the walk ───────────────────────────────────────

run_stack "$(stack_pr 9 haacked/topic haacked/loop)" "$(stack_pr 40 haacked/loop haacked/topic)"
assert "a cycle finishes before the deadline" test "$RC" -ne 124
assert "a cycle exits 0" test "$RC" -eq 0
assert "a cycle lists each PR once" test "$OUT" = "$URL9 (Approved)
  #40 Approved
> #9 Approved
  haacked/loop"

# ── Test: an unknown default branch skips the stack ─────────────────────────

# Without the default branch, a PR from main would look like a parent.
git symbolic-ref --delete refs/remotes/origin/HEAD
run_stack "$ON_PARENT" "$PARENT" "$(stack_pr 21 main haacked/release)"
git symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
assert "an unknown default branch prints only the status line" test "$OUT" = "$URL9 (Approved)"
assert_not "an unknown default branch never looks the stack up" grep -q -- '--state open' "$CALLS"

# ── Test: an explicit PR number shows its stack ──────────────────────────────

TWELVE=$(stack_pr 12 haacked/twelve haacked/parent)
run_git_pr --tty GH_VIEW_JSON="$TWELVE" \
    GH_STACK_JSON="$(prs "$TWELVE" "$PARENT" "$(stack_pr 13 haacked/thirteen haacked/twelve REVIEW_REQUIRED)")" \
    -- 12
assert "an explicit PR shows its stack" test "$OUT" = "$URL12 (Approved)
  #13 Review required
> #12 Approved
  #10 Approved
  main"

print_results
