#!/usr/bin/env bash
# Tests for ran-report.sh, the per-branch workflow checklist.
#
# The report's whole difficulty is that the hook captures a sha at invocation
# while most of these steps commit afterwards, so a logged sha almost never
# equals HEAD. A sha-equality test would therefore mark a finished branch
# entirely stale and could never print "commit @ <HEAD>". These fixtures pin the
# attribution rule that replaces it: every branch commit belongs to the most
# recent logged entry before it, and a step is stale only when a commit after
# its last run belongs to an earlier-pipeline step or to nobody.
#
# Usage: test-ran-report.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
READER="${SCRIPT_DIR}/../ran-report.sh"

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
STATE_ROOT="${FAKE_HOME}/.local/state/ran"
LOG_DIR="${STATE_ROOT}/haacked/dotfiles"
LOG_FILE="${LOG_DIR}/haacked-breadcrumbs.jsonl"
OUT_FILE="${TEST_ROOT}/stdout"
ERR_FILE="${TEST_ROOT}/stderr"
READER_STATUS=0

SHIM_BIN="${TEST_ROOT}/bin"
mkdir -p "$FAKE_HOME" "$LOG_DIR" "$SHIM_BIN"

# A detached checkout resolves its branch by asking GitHub which PR has HEAD as
# its head commit. This shim answers from GH_API_JSON, where SELF stands in for
# the sha under test, so the suite stays offline. The report's PR lookup is a
# GraphQL call, which the shim answers from GH_GRAPHQL_JSON. An unset
# GH_GRAPHQL_JSON fails the call the way an unreachable GitHub does.
cat > "${SHIM_BIN}/gh" <<'SHIM'
#!/usr/bin/env bash
[ "$1" = api ] || exit 1
if [ "$2" = graphql ]; then
    [ -n "${GH_GRAPHQL_JSON-}" ] || exit 1
    printf '%s\n' "$GH_GRAPHQL_JSON"
    exit 0
fi
printf '%s' "${GH_API_JSON-[]}" | sed "s/SELF/${GIT_PR_HEAD_SHA}/g" | jq -r "${4-.}"
SHIM
chmod +x "${SHIM_BIN}/gh"

# An inherited state-directory override would point the reader at the real log.
unset RAN_STATE_DIR

# The report renders clock times, so the fixtures fix the zone. Isolating git's
# global config keeps a stray commit.gpgsign or template hook out of the
# throwaway repos.
export TZ=UTC
export GIT_CONFIG_GLOBAL="${TEST_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"

# 2026-08-27T23:00:00Z, the evening of the fixtures' day, so a run logged that
# day renders as a bare clock time.
FIXTURE_NOW=1787871600
unset RAN_NOW
unset GH_GRAPHQL_JSON

cleanup() {
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
    passes=$((passes + 1))
}

fail() {
    echo "FAIL: $1"
    failures=$((failures + 1))
}

check() { # description command [args...]
    local description="$1"
    shift
    if "$@"; then
        pass
    else
        fail "$description"
    fi
}

check_eq() { # description actual expected
    if [[ "$2" == "$3" ]]; then
        pass
    else
        fail "$1"
        echo "  expected [$3], got [$2]"
    fi
}

contains() { # haystack needle
    [[ "$1" == *"$2"* ]]
}

summary() {
    echo ""
    echo "Passed: ${passes}, Failed: ${failures}"
}

commit_at() { # repo iso_ts message
    GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
        git -C "$1" commit -q --allow-empty -m "$3"
}

# An empty commit has no patch-id, so the rebase fixtures need real content.
commit_file_at() { # repo iso_ts file content message
    printf '%s\n' "$4" > "$1/$3"
    git -C "$1" add "$3"
    GIT_AUTHOR_DATE="$2" GIT_COMMITTER_DATE="$2" \
        git -C "$1" commit -q -m "$5"
}

# The GraphQL answer for one PR on the branch, as seen by the user "haacked".
# head is a full sha, ci is a statusCheckRollup state or "null", and threads is
# a JSON array of `thread` nodes.
pr_json() { # number state head ci [threads] [draft]
    jq -n -c --argjson number "$1" --arg state "$2" --arg head "$3" --arg ci "$4" \
        --argjson threads "${5:-[]}" --argjson draft "${6:-false}" \
        '{data: {viewer: {login: "haacked"}, repository: {pullRequests: {nodes: [
            {number: $number, state: $state, isDraft: $draft, isCrossRepository: false,
             headRefOid: $head,
             commits: {nodes: [{commit: {statusCheckRollup:
                 (if $ci == "null" then null else {state: $ci} end)}}]},
             reviewThreads: {nodes: $threads}}]}}}}'
}

# A review thread whose latest comment author posted at ts.
thread() { # ts author [resolved]
    jq -n -c --arg ts "$1" --arg author "$2" --argjson resolved "${3:-false}" \
        '{isResolved: $resolved, comments: {nodes: [{createdAt: $ts, author: {login: $author}}]}}'
}

NO_PR_JSON='{"data":{"viewer":{"login":"haacked"},"repository":{"pullRequests":{"nodes":[]}}}}'

short() { # repo [rev]
    git -C "$1" rev-parse --short "${2:-HEAD}"
}

# origin/main is the merge-base the "commits since the merge-base" count and the
# whole attribution window are measured against.
new_repo() { # name -> prints repo path
    local dir="${TEST_ROOT}/repos/$1"
    rm -rf "$dir"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" remote add origin "git@github.com:haacked/dotfiles.git"
    commit_at "$dir" "2026-08-27T12:00:00Z" "base"
    git -C "$dir" update-ref refs/remotes/origin/main HEAD
    git -C "$dir" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
    git -C "$dir" checkout -q -b haacked/breadcrumbs
    printf '%s\n' "$dir"
}

entry() { # ts step command source sha [status]
    jq -c -n --arg ts "$1" --arg step "$2" --arg command "$3" \
        --arg source "$4" --arg sha "$5" --arg status "${6:-started}" \
        '{ts: $ts, step: $step, command: $command, status: $status, source: $source,
          sha: $sha, session: "3dc249e3", agent: null}'
}

write_log() { # entry...
    mkdir -p "$LOG_DIR"
    printf '%s\n' "$@" > "$LOG_FILE"
}

clear_log() {
    rm -f "$LOG_FILE"
}

run_reader() { # repo [args...]
    local repo="$1"
    shift
    : > "$OUT_FILE"
    : > "$ERR_FILE"
    (
        cd "$repo" || exit 1
        PATH="${SHIM_BIN}:${PATH}" HOME="$FAKE_HOME" TZ=UTC GH_TOKEN="" GITHUB_TOKEN="" \
            RAN_NOW="${RAN_NOW:-$FIXTURE_NOW}" "$READER" "$@"
    ) > "$OUT_FILE" 2> "$ERR_FILE"
    READER_STATUS=$?
}

# Report rows are "<marker> <step> …", so the first two fields identify a row
# without the marker's multibyte width getting in the way.
marker() { # step
    awk -v s="$1" 'NF >= 2 && $2 == s { print $1; exit }' "$OUT_FILE"
}

row() { # step
    awk -v s="$1" 'NF >= 2 && $2 == s { print; exit }' "$OUT_FILE"
}

out_has() { # fixed string
    grep -Fq "$1" "$OUT_FILE"
}

out_lacks() { # fixed string
    # The file must be non-empty: grep against no output would make every
    # "lacks" assertion pass for a reader that printed nothing at all.
    [[ -s "$OUT_FILE" ]] && ! grep -Fq "$1" "$OUT_FILE"
}

is_json() {
    jq -e . "$OUT_FILE" > /dev/null 2>&1
}

json_has_error() {
    jq -e 'has("error")' "$OUT_FILE" > /dev/null 2>&1
}

if [[ ! -x "$READER" ]]; then
    fail "ai/skills/ran/scripts/ran-report.sh exists and is executable (implementation not written yet)"
    summary
    exit 1
fi

# ── The plan's worked example, rendered ──────────────────────────────────────
# Two commits precede everything logged, then /create-pr at 13:40, /simplify at
# 14:02 and /commit at 14:09, whose commit lands half a minute later. Every
# marker in the plan's preview comes out of this one timeline.

PREVIEW=$(new_repo preview)
commit_at "$PREVIEW" "2026-08-27T13:00:00Z" "first"
commit_at "$PREVIEW" "2026-08-27T13:30:00Z" "second"
PREVIEW_MID=$(short "$PREVIEW")
commit_at "$PREVIEW" "2026-08-27T14:09:30Z" "third"
PREVIEW_HEAD=$(short "$PREVIEW")

write_log \
    "$(entry "2026-08-27T13:40:00Z" create-pr /create-pr typed "$PREVIEW_MID")" \
    "$(entry "2026-08-27T14:02:11Z" simplify /simplify typed "$PREVIEW_MID")" \
    "$(entry "2026-08-27T14:09:00Z" commit /commit typed "$PREVIEW_MID")"

run_reader "$PREVIEW"

check_eq "the worked example exits 0" "$READER_STATUS" "0"
check_eq "implement counts the commits since the merge-base" "$(marker implement)" "✓"
check_eq "a step whose later commits all belong to later steps is fresh" \
    "$(marker simplify)" "✓"
check_eq "a step that never ran once earlier steps have is due" \
    "$(marker review-code)" "✗"
check_eq "a clean tree with commits makes commit fresh" \
    "$(marker commit)" "✓"
check_eq "without GitHub, a step followed by an earlier step's commit is stale" \
    "$(marker create-pr)" "⚠"
check_eq "a step that is not due yet is neither missing nor stale" \
    "$(marker ci-monitor)" "·"

check "the header names the branch at HEAD" \
    out_has "Branch haacked/breadcrumbs @ ${PREVIEW_HEAD}"
check "a non-committing step shows its invocation sha" \
    contains "$(row simplify)" "@ ${PREVIEW_MID}"
check "a stale row names the commit and the step it came from" \
    contains "$(row create-pr)" "(stale: ${PREVIEW_HEAD} by commit)"
check "the outstanding steps are summarised" \
    out_has "2 steps outstanding: create-pr, review-code"
check "the report says when the PR rows fell back to the log" \
    out_has "GitHub did not answer"

# The plan's preview sketched six steps in the order they happened to run and
# blamed staleness on HEAD moving. The report renders every step in pipeline
# order instead, because the question it answers is which step is missing, and
# names attribution as the cause, because HEAD moving is not the criterion: a
# step that commits always moves HEAD past its own run. Shas come from the
# fixture.
EXPECTED="${TEST_ROOT}/expected"
{
    printf 'Branch haacked/breadcrumbs @ %s\n' "$PREVIEW_HEAD"
    printf '\n'
    printf '  ✓ implement           3 commits\n'
    printf '  ✓ simplify            14:02  @ %s\n' "$PREVIEW_MID"
    printf '  · comment-cleanup     not yet run\n'
    printf '  ✓ commit              nothing uncommitted\n'
    printf '  ⚠ create-pr           13:40  @ %s (stale: %s by commit)\n' "$PREVIEW_MID" "$PREVIEW_HEAD"
    printf '  ✗ review-code         never run\n'
    printf '  · address-pr-reviews  not yet run\n'
    printf '  · ci-monitor          not yet run\n'
    printf '\n'
    printf '2 steps outstanding: create-pr, review-code\n'
    printf 'GitHub did not answer, so these rows read only the log: create-pr, address-pr-reviews, ci-monitor.\n'
} > "$EXPECTED"

if diff -u "$EXPECTED" "$OUT_FILE" > "${TEST_ROOT}/preview.diff" 2>&1; then
    pass
else
    fail "the worked example renders line for line"
    sed 's/^/  /' "${TEST_ROOT}/preview.diff"
fi

# ── A finished pipeline reports nothing outstanding ──────────────────────────
# Every step ran in order and the one commit they produced belongs to /commit.
# simplify's logged sha is not HEAD, so a sha-equality test would call this
# branch entirely stale; attribution must call it done.

DONE=$(new_repo finished)
commit_at "$DONE" "2026-08-27T13:00:00Z" "first"
DONE_FIRST=$(short "$DONE")
commit_at "$DONE" "2026-08-27T14:02:30Z" "second"
DONE_HEAD=$(short "$DONE")

happy_path_log() {
    write_log \
        "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$DONE_FIRST")" \
        "$(entry "2026-08-27T14:01:00Z" comment-cleanup /comment-cleanup typed "$DONE_FIRST")" \
        "$(entry "2026-08-27T14:02:00Z" commit /commit typed "$DONE_FIRST")" \
        "$(entry "2026-08-27T14:04:00Z" create-pr /create-pr typed "$DONE_HEAD")" \
        "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$DONE_HEAD")" \
        "$(entry "2026-08-27T14:05:30Z" review-code null skill "$DONE_HEAD" done)" \
        "$(entry "2026-08-27T14:06:00Z" address-pr-reviews /address-pr-reviews typed "$DONE_HEAD")" \
        "$(entry "2026-08-27T14:06:30Z" address-pr-reviews null skill "$DONE_HEAD" done)" \
        "$(entry "2026-08-27T14:07:00Z" ci-monitor /ci-monitor typed "$DONE_HEAD")" \
        "$(entry "2026-08-27T14:08:00Z" explain-open /explain-open typed "$DONE_HEAD")" \
        "$(entry "2026-08-27T14:09:00Z" go /go typed "$DONE_HEAD")"
}

happy_path_log
run_reader "$DONE"

check_eq "a finished pipeline exits 0" "$READER_STATUS" "0"
check "a finished pipeline flags nothing stale" out_lacks "⚠"
check "a finished pipeline flags nothing missing" out_lacks "✗"
check_eq "simplify is fresh" "$(marker simplify)" "✓"
check_eq "comment-cleanup is fresh" "$(marker comment-cleanup)" "✓"
check_eq "commit is fresh" "$(marker commit)" "✓"
check_eq "create-pr is fresh" "$(marker create-pr)" "✓"
check_eq "review-code is fresh" "$(marker review-code)" "✓"
check_eq "ci-monitor is fresh" "$(marker ci-monitor)" "✓"
check "simplify stays fresh even though its logged sha is not HEAD" \
    contains "$(row simplify)" "@ ${DONE_FIRST}"

# /go seeds a review step only from a "fresh" row in this payload, so the
# finished pipeline is the only fixture that can produce the value it acts on.
run_reader "$DONE" --json

check_eq "--json reports the fresh status /go seeds review-code from" \
    "$(jq -r '.rows[] | select(.step == "review-code") | .status' "$OUT_FILE")" "fresh"
check_eq "--json reports the fresh status /go seeds address-pr-reviews from" \
    "$(jq -r '.rows[] | select(.step == "address-pr-reviews") | .status' "$OUT_FILE")" "fresh"

# ── A review step needs the record its skill writes when it finishes ─────────
# The hook records a command when it is submitted, so an abandoned review logs
# what a finished one logs. The two review steps count only the "done" record.

review_started_only_log() {
    write_log \
        "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$DONE_FIRST")" \
        "$(entry "2026-08-27T14:02:00Z" commit /commit typed "$DONE_FIRST")" \
        "$(entry "2026-08-27T14:04:00Z" create-pr /create-pr typed "$DONE_HEAD")" \
        "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$DONE_HEAD")"
}

review_started_only_log
run_reader "$DONE"

check_eq "a review abandoned at the prompt is not fresh" "$(marker review-code)" "✗"
check "a review abandoned at the prompt is outstanding" out_has "review-code"
check_eq "the step before it, which needs no completion record, stays fresh" \
    "$(marker create-pr)" "✓"

# A skill records its own completion wherever it runs, including Codex, where no
# hook wrote the invocation. The "done" record alone has to be enough.
write_log \
    "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$DONE_FIRST")" \
    "$(entry "2026-08-27T14:02:00Z" commit /commit typed "$DONE_FIRST")" \
    "$(entry "2026-08-27T14:04:00Z" create-pr /create-pr typed "$DONE_HEAD")" \
    "$(entry "2026-08-27T14:05:30Z" review-code null skill "$DONE_HEAD" done)"
run_reader "$DONE"

check_eq "a completion record with no invocation before it counts" \
    "$(marker review-code)" "✓"

# Entries written before the status field exists carry none, so they must not
# satisfy a review step: an old branch is offered the review again.
write_log \
    "$(jq -c -n --arg sha "$DONE_HEAD" \
        '{ts: "2026-08-27T14:04:00Z", step: "create-pr", command: "/create-pr",
          source: "typed", sha: $sha, session: "3dc249e3", agent: null}')" \
    "$(jq -c -n --arg sha "$DONE_HEAD" \
        '{ts: "2026-08-27T14:05:00Z", step: "review-code", command: "/review-code",
          source: "typed", sha: $sha, session: "3dc249e3", agent: null}')"
run_reader "$DONE"

check_eq "an entry predating the status field does not satisfy a review step" \
    "$(marker review-code)" "✗"

# A commit landing after a step reported finished is work that step never saw,
# so the completion record must not claim it. Here the review finishes at 14:06
# and more work is committed at 14:20, still inside the attribution window, so
# the verdict turns entirely on which record the commit attributes to: the
# `commit` step that preceded it, not the review that had already finished.
AFTER_DONE=$(new_repo after-done)
commit_at "$AFTER_DONE" "2026-08-27T14:05:30Z" "committed by the commit step"
commit_at "$AFTER_DONE" "2026-08-27T14:20:00Z" "typed by hand"
AFTER_DONE_FIRST=$(short "$AFTER_DONE" HEAD~1)
write_log \
    "$(entry "2026-08-27T13:50:00Z" create-pr /create-pr typed "$AFTER_DONE_FIRST")" \
    "$(entry "2026-08-27T13:52:00Z" review-code /review-code typed "$AFTER_DONE_FIRST")" \
    "$(entry "2026-08-27T14:05:00Z" commit /commit typed "$AFTER_DONE_FIRST")" \
    "$(entry "2026-08-27T14:06:00Z" review-code null skill "$AFTER_DONE_FIRST" done)"
run_reader "$AFTER_DONE"

check_eq "a commit after the completion record makes the review stale" \
    "$(marker review-code)" "⚠"
check_eq "the commit step that produced its own commit stays fresh" \
    "$(marker commit)" "✓"

# ── A hand-made commit invalidates everything before it ──────────────────────
# The same finished pipeline plus one commit nobody logged. The plan states this
# attributes to `manual` and makes every prior step stale.

MANUAL_TS="2026-08-28T09:00:00Z"
commit_at "$DONE" "$MANUAL_TS" "hand-typed"
happy_path_log
# Read the next morning, ten hours after the fixtures' evening.
RAN_NOW=$((FIXTURE_NOW + 36000)) run_reader "$DONE"

check_eq "an unlogged commit still exits 0" "$READER_STATUS" "0"
check "an unlogged commit makes something stale" out_has "⚠"
check_eq "an unlogged commit staled simplify" "$(marker simplify)" "⚠"
check_eq "an unlogged commit leaves commit fresh, since the tree is clean" \
    "$(marker commit)" "✓"
check_eq "an unlogged commit staled create-pr" "$(marker create-pr)" "⚠"
check_eq "an unlogged commit staled review-code" "$(marker review-code)" "⚠"
check "the stale row names the hand-made commit" \
    contains "$(row simplify)" "(stale: $(short "$DONE") by hand)"
check "a run from an earlier day shows the day" \
    contains "$(row simplify)" "Thu 14:00"

# ── A branch with no history yet ─────────────────────────────────────────────
# The log starts at install, so an older branch has commits and no entries.

EMPTY=$(new_repo empty)
commit_at "$EMPTY" "2026-08-27T13:00:00Z" "first"
EMPTY_HEAD=$(short "$EMPTY")
clear_log
run_reader "$EMPTY"

check_eq "an empty log exits 0" "$READER_STATUS" "0"
check "an empty log still reports the branch" \
    out_has "Branch haacked/breadcrumbs @ ${EMPTY_HEAD}"
check_eq "an empty log credits the commits that exist" "$(marker implement)" "✓"
check "an empty log claims no step has run" test "$(marker simplify)" != "✓"

# ── --json ───────────────────────────────────────────────────────────────────

happy_path_log
run_reader "$DONE" --json

check_eq "--json exits 0" "$READER_STATUS" "0"
check "--json emits parseable JSON" is_json
check "--json names the steps it rendered" out_has "simplify"
check_eq "--json reports a stale status, which seeds nothing" \
    "$(jq -r '.rows[] | select(.step == "review-code") | .status' "$OUT_FILE")" "stale"

# Per the plan's JSON-error convention, --json never exits non-zero; it reports
# the problem in the payload.
NOT_A_REPO="${TEST_ROOT}/not-a-repo"
mkdir -p "$NOT_A_REPO"
run_reader "$NOT_A_REPO" --json

check_eq "--json outside a repo exits 0" "$READER_STATUS" "0"
check "--json outside a repo reports an error field" json_has_error

# ── Detached HEAD ────────────────────────────────────────────────────────────
# An agent harness checks the PR head out detached, and log-step-done.sh records
# against the PR's head ref from there. The report has to read that same log
# back, or the branch's finished steps all render as never run.
#
# Each case gets its own repo. A resolved branch caches under the checkout's
# git dir. Reusing one repo across cases with different GH_API_JSON values
# would let an earlier case's cache answer a later case instead of the tier
# under test.

DETACHED=$(new_repo detached)
git -C "$DETACHED" checkout -q --detach HEAD
happy_path_log
GH_API_JSON='[{"head":{"sha":"SELF","ref":"haacked/breadcrumbs"},"state":"open"}]' \
    run_reader "$DETACHED"

check_eq "a detached HEAD exits 0" "$READER_STATUS" "0"
check "it reports the branch its PR heads" out_has "Branch haacked/breadcrumbs"
check_eq "it reads the log that branch's records land in" "$(marker simplify)" "✓"

DETACHED_NO_PR=$(new_repo detached-no-pr)
git -C "$DETACHED_NO_PR" checkout -q --detach HEAD
GH_API_JSON='[]' run_reader "$DETACHED_NO_PR"
check "a detached HEAD with no PR fails" test "$READER_STATUS" -ne 0

# ── Detached HEAD after a commit ────────────────────────────────────────────
# address-pr-reviews resolves the branch once, via RAN_BRANCH or this same
# network lookup, and hands it to log-step-done.sh. A later commit under
# --no-push, or before a push completes, moves HEAD off the PR head that
# lookup matched. A later /ran here then has no HEAD the network tier can
# match either. The cache resolve_branch_name wrote on the first lookup has to
# answer this one.

DETACHED_CACHE=$(new_repo detached-cache)
git -C "$DETACHED_CACHE" checkout -q --detach HEAD
happy_path_log
GH_API_JSON='[{"head":{"sha":"SELF","ref":"haacked/breadcrumbs"},"state":"open"}]' \
    run_reader "$DETACHED_CACHE"
check_eq "the first lookup, still at the PR head, exits 0" "$READER_STATUS" "0"

commit_at "$DETACHED_CACHE" "2026-08-28T09:00:00Z" "review fix"
GH_API_JSON='[]' run_reader "$DETACHED_CACHE"
check_eq "a later run past that commit still exits 0" "$READER_STATUS" "0"
check "it still reports the cached branch" out_has "Branch haacked/breadcrumbs"

# ── GitHub and the tree answer what the log can only guess at ────────────────
# A PR an earlier session opened, a commit made with plain `git commit`, and CI
# watched without /ci-monitor all leave no record in the log. The log here has
# no commit, create-pr, or ci-monitor entry at all.

WORLD=$(new_repo world)
commit_at "$WORLD" "2026-08-27T13:00:00Z" "first"
WORLD_FIRST=$(short "$WORLD")
WORLD_FIRST_FULL=$(git -C "$WORLD" rev-parse HEAD)
commit_at "$WORLD" "2026-08-27T14:02:30Z" "second"
WORLD_HEAD=$(short "$WORLD")
WORLD_HEAD_FULL=$(git -C "$WORLD" rev-parse HEAD)
WORLD_PR=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS)

write_log \
    "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$WORLD_FIRST")" \
    "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$WORLD_HEAD")" \
    "$(entry "2026-08-27T14:05:30Z" review-code null skill "$WORLD_HEAD" done)" \
    "$(entry "2026-08-27T14:06:30Z" address-pr-reviews null skill "$WORLD_HEAD" done)"

GH_GRAPHQL_JSON="$WORLD_PR" run_reader "$WORLD"

check_eq "a GitHub-backed report exits 0" "$READER_STATUS" "0"
check_eq "an open PR makes create-pr fresh with no log record" "$(marker create-pr)" "✓"
check "the create-pr row names the PR" contains "$(row create-pr)" "#42 open"
check_eq "a clean tree makes commit fresh with no log record" "$(marker commit)" "✓"
check_eq "passing checks on HEAD make ci-monitor fresh" "$(marker ci-monitor)" "✓"
check "the ci-monitor row names the commit CI ran on" \
    contains "$(row ci-monitor)" "passed on ${WORLD_HEAD}"
check "nothing is outstanding" out_has "Nothing outstanding."
check "a GitHub answer prints no fallback note" out_lacks "GitHub did not answer"

GH_GRAPHQL_JSON="$WORLD_PR" run_reader "$WORLD" --json
check_eq "--json says GitHub answered" "$(jq -r .github "$OUT_FILE")" "true"

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS "[]" true) run_reader "$WORLD"
check "a draft PR says so" contains "$(row create-pr)" "#42 draft"

GH_GRAPHQL_JSON=$(pr_json 42 MERGED "$WORLD_HEAD_FULL" SUCCESS) run_reader "$WORLD"
check_eq "a merged PR keeps create-pr fresh" "$(marker create-pr)" "✓"
check "a merged PR says so" contains "$(row create-pr)" "#42 merged"

GH_GRAPHQL_JSON=$(pr_json 42 CLOSED "$WORLD_HEAD_FULL" SUCCESS) run_reader "$WORLD"
check_eq "a closed PR leaves create-pr missing" "$(marker create-pr)" "✗"
check "a closed PR says so" contains "$(row create-pr)" "#42 closed"

GH_GRAPHQL_JSON="$NO_PR_JSON" run_reader "$WORLD"
check_eq "no PR leaves create-pr missing once commits exist" "$(marker create-pr)" "✗"
check "no PR says so" contains "$(row create-pr)" "no PR"
check_eq "no PR leaves ci-monitor nothing to watch" "$(marker ci-monitor)" "·"

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" PENDING) run_reader "$WORLD"
check_eq "running checks get their own marker" "$(marker ci-monitor)" "…"
check "the row says CI is running on HEAD" \
    contains "$(row ci-monitor)" "running on ${WORLD_HEAD}"
check "running checks are not outstanding" out_has "Nothing outstanding."

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" FAILURE) run_reader "$WORLD"
check_eq "failing checks need another pass" "$(marker ci-monitor)" "⚠"
check "the row says CI is failing on HEAD" \
    contains "$(row ci-monitor)" "failing on ${WORLD_HEAD}"
check "failing checks are outstanding" out_has "1 step outstanding: ci-monitor"

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" null) run_reader "$WORLD"
check_eq "a head with no checks yet is not outstanding" "$(marker ci-monitor)" "·"

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_FIRST_FULL" SUCCESS) run_reader "$WORLD"
check_eq "a PR head behind HEAD means CI has not seen HEAD" "$(marker ci-monitor)" "⚠"
check "the row counts the commits not pushed" \
    contains "$(row ci-monitor)" "1 commit not pushed"

# The pass recorded its completion at 14:06:30. address-pr-reviews leaves a
# thread it fixed unresolved. It also leaves a dismissed human comment
# unresolved for the reviewer to answer. Neither may demote the row. A reviewer comment
# posted after the pass is one the pass never saw, so it does. The PR alone
# never promotes the row, because /go seeds this step only from a fresh row.
SEEN_BY_PASS=$(thread "2026-08-27T14:03:00Z" copilot)
NEW_COMMENT=$(thread "2026-08-27T14:10:00Z" reviewer)
OWN_REPLY=$(thread "2026-08-27T14:10:00Z" haacked)
RESOLVED_LATER=$(thread "2026-08-27T14:10:00Z" reviewer true)

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS \
    "[$SEEN_BY_PASS,$OWN_REPLY,$RESOLVED_LATER]") run_reader "$WORLD"
check_eq "threads the pass saw, answered, or saw resolved keep the row fresh" \
    "$(marker address-pr-reviews)" "✓"

GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS \
    "[$SEEN_BY_PASS,$NEW_COMMENT]") run_reader "$WORLD"
check_eq "a reviewer comment after the pass makes address-pr-reviews stale" \
    "$(marker address-pr-reviews)" "⚠"
check "the row counts the new comments" \
    contains "$(row address-pr-reviews)" "(stale: 1 new review comment)"
GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS "[$NEW_COMMENT]") \
    run_reader "$WORLD" --json
check_eq "--json reports the stale status /go seeds nothing from" \
    "$(jq -r '.rows[] | select(.step == "address-pr-reviews") | .status' "$OUT_FILE")" "stale"

# The pass fetches comments when it starts and records `done` when it ends,
# after its prompts and its push. A comment posted in between came after the
# fetch, so the pass may never have seen it.
write_log \
    "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$WORLD_FIRST")" \
    "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$WORLD_HEAD")" \
    "$(entry "2026-08-27T14:05:30Z" review-code null skill "$WORLD_HEAD" done)" \
    "$(entry "2026-08-27T14:06:00Z" address-pr-reviews /address-pr-reviews typed "$WORLD_HEAD")" \
    "$(entry "2026-08-27T14:20:00Z" address-pr-reviews null skill "$WORLD_HEAD" done)"
GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS \
    "[$(thread "2026-08-27T14:10:00Z" reviewhog)]") run_reader "$WORLD"
check_eq "a comment posted while the pass ran makes address-pr-reviews stale" \
    "$(marker address-pr-reviews)" "⚠"

# A later pass with no started record, as from Codex, handled that comment. The
# earlier pass's start belongs to the earlier pass.
write_log \
    "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$WORLD_FIRST")" \
    "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$WORLD_HEAD")" \
    "$(entry "2026-08-27T14:05:30Z" review-code null skill "$WORLD_HEAD" done)" \
    "$(entry "2026-08-27T14:06:00Z" address-pr-reviews /address-pr-reviews typed "$WORLD_HEAD")" \
    "$(entry "2026-08-27T14:20:00Z" address-pr-reviews null skill "$WORLD_HEAD" done)" \
    "$(entry "2026-08-27T16:00:00Z" address-pr-reviews null skill "$WORLD_HEAD" done)"
GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS \
    "[$(thread "2026-08-27T15:00:00Z" reviewer)]") run_reader "$WORLD"
check_eq "a pass with no started record does not borrow an earlier pass's start" \
    "$(marker address-pr-reviews)" "✓"

# Only the first 100 threads are read, so the rest could hold a new comment.
GH_GRAPHQL_JSON=$(pr_json 42 OPEN "$WORLD_HEAD_FULL" SUCCESS |
    jq -c '.data.repository.pullRequests.nodes[0].reviewThreads.pageInfo = {hasNextPage: true}') \
    run_reader "$WORLD"
check_eq "a PR with threads past the first 100 cannot read fresh" \
    "$(marker address-pr-reviews)" "⚠"
check "the row says not every thread was read" \
    contains "$(row address-pr-reviews)" "over 100 review threads"

printf 'draft\n' > "${WORLD}/scratch.txt"
GH_GRAPHQL_JSON="$WORLD_PR" run_reader "$WORLD"
check_eq "an uncommitted file makes commit stale" "$(marker commit)" "⚠"
check "the commit row counts the uncommitted files" \
    contains "$(row commit)" "1 file uncommitted"
rm -f "${WORLD}/scratch.txt"

# ── A rebase keeps the runs it carried ───────────────────────────────────────
# A rebase onto a newer main rewrites every branch commit with a new sha and a
# new committer time. Read by committer time, each one lands days after the last
# logged command and reads as made by hand, so every step goes stale over work
# it already saw. A commit whose patch matches one the branch held before keeps
# that commit's time.

REBASED=$(new_repo rebased)
commit_file_at "$REBASED" "2026-08-27T13:00:00Z" work.txt "first" "first"
REBASED_FIRST=$(short "$REBASED")
commit_file_at "$REBASED" "2026-08-27T14:02:30Z" work.txt "second" "simplify fixes"
REBASED_OLD_HEAD=$(short "$REBASED")
write_log \
    "$(entry "2026-08-27T14:00:00Z" simplify /simplify typed "$REBASED_FIRST")" \
    "$(entry "2026-08-27T14:02:00Z" commit /commit typed "$REBASED_FIRST")" \
    "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$REBASED_OLD_HEAD")" \
    "$(entry "2026-08-27T14:05:30Z" review-code null skill "$REBASED_OLD_HEAD" done)"

git -C "$REBASED" checkout -q main
commit_file_at "$REBASED" "2026-08-30T09:00:00Z" upstream.txt "upstream" "upstream"
git -C "$REBASED" update-ref refs/remotes/origin/main HEAD
git -C "$REBASED" checkout -q haacked/breadcrumbs
GIT_COMMITTER_DATE="2026-08-31T10:00:00Z" git -C "$REBASED" rebase -q origin/main
REBASED_HEAD=$(short "$REBASED")

run_reader "$REBASED"
check "the fixture rebased onto a new sha" test "$REBASED_HEAD" != "$REBASED_OLD_HEAD"
check_eq "a rebased branch exits 0" "$READER_STATUS" "0"
check_eq "simplify stays fresh across a rebase" "$(marker simplify)" "✓"
check_eq "review-code stays fresh across a rebase" "$(marker review-code)" "✓"
check "a rebased step shows the commit's new sha" \
    contains "$(row simplify)" "@ $(short "$REBASED" HEAD~1)"

# An amend keeps the author time but changes the patch, so nothing matches it.
# Crediting it by author time would keep the review fresh over unreviewed work.
printf 'amended\n' > "${REBASED}/work.txt"
git -C "$REBASED" add work.txt
GIT_COMMITTER_DATE="2026-08-31T12:00:00Z" git -C "$REBASED" commit -q --amend --no-edit
run_reader "$REBASED"
check_eq "an amend that changed the patch makes review-code stale" \
    "$(marker review-code)" "⚠"
check "the stale row says the commit was rewritten" \
    contains "$(row review-code)" "(stale: $(short "$REBASED") rewritten)"
check "a logged sha the amend replaced says the branch no longer holds it" \
    contains "$(row review-code)" "@ ${REBASED_OLD_HEAD}, no longer on the branch"
check "a logged sha a rebase carried over shows its replacement instead" \
    out_lacks "${REBASED_FIRST}, no longer on the branch"

# A default patch-id ignores whitespace, so a dedent that moves a call out of
# its `if` would match the reviewed commit and keep the review fresh.
INDENTED=$(new_repo indented)
commit_file_at "$INDENTED" "2026-08-27T13:30:00Z" m.py $'if x:\n    a()\n    b()' "add m"
write_log \
    "$(entry "2026-08-27T14:05:00Z" review-code /review-code typed "$(short "$INDENTED")")" \
    "$(entry "2026-08-27T14:06:00Z" review-code null skill "$(short "$INDENTED")" done)"
printf 'if x:\n    a()\nb()\n' > "${INDENTED}/m.py"
git -C "$INDENTED" add m.py
GIT_COMMITTER_DATE="2026-08-28T09:00:00Z" git -C "$INDENTED" commit -q --amend --no-edit
run_reader "$INDENTED"
check_eq "an amend that changes only indentation makes review-code stale" \
    "$(marker review-code)" "⚠"

# Patch A is amended to B, B is reviewed, and a second amend restores A. The
# reflog still holds the first A, but the review ran on a branch without it.
AMEND_BACK=$(new_repo amend-back)
commit_file_at "$AMEND_BACK" "2026-08-27T10:00:00Z" work.txt "A" "work"
printf 'B\n' > "${AMEND_BACK}/work.txt"
git -C "$AMEND_BACK" add work.txt
GIT_COMMITTER_DATE="2026-08-27T11:00:00Z" git -C "$AMEND_BACK" commit -q --amend --no-edit
AMEND_BACK_B=$(short "$AMEND_BACK")
write_log \
    "$(entry "2026-08-27T11:55:00Z" review-code /review-code typed "$AMEND_BACK_B")" \
    "$(entry "2026-08-27T12:00:00Z" review-code null skill "$AMEND_BACK_B" done)"
printf 'A\n' > "${AMEND_BACK}/work.txt"
git -C "$AMEND_BACK" add work.txt
GIT_COMMITTER_DATE="2026-08-27T13:00:00Z" git -C "$AMEND_BACK" commit -q --amend --no-edit
run_reader "$AMEND_BACK"
check_eq "a patch restored after the review ran without it makes review-code stale" \
    "$(marker review-code)" "⚠"
check "the restored commit reads as rewritten" \
    contains "$(row review-code)" "(stale: $(short "$AMEND_BACK") rewritten)"

# A commit made in another clone at 13:00 reaches this branch by a fetch after
# simplify ran at 13:30. It belongs to the first run whose tip holds it, so a
# later rebase leaves it with comment-cleanup instead of making it hand-made.
FETCHED=$(new_repo fetched)
commit_file_at "$FETCHED" "2026-08-27T12:00:00Z" first.txt "first" "first"
FETCHED_FIRST=$(short "$FETCHED")
git -C "$FETCHED" checkout -q -b elsewhere
commit_file_at "$FETCHED" "2026-08-27T13:00:00Z" second.txt "second" "made in another clone"
FETCHED_SECOND=$(short "$FETCHED")
git -C "$FETCHED" checkout -q haacked/breadcrumbs
git -C "$FETCHED" merge -q --ff-only elsewhere
write_log \
    "$(entry "2026-08-27T13:30:00Z" simplify /simplify typed "$FETCHED_FIRST")" \
    "$(entry "2026-08-27T13:45:00Z" comment-cleanup /comment-cleanup typed "$FETCHED_SECOND")"
git -C "$FETCHED" checkout -q main
commit_file_at "$FETCHED" "2026-08-30T09:00:00Z" upstream.txt "upstream" "upstream"
git -C "$FETCHED" update-ref refs/remotes/origin/main HEAD
git -C "$FETCHED" checkout -q haacked/breadcrumbs
GIT_COMMITTER_DATE="2026-08-31T10:00:00Z" git -C "$FETCHED" rebase -q origin/main
run_reader "$FETCHED"
check_eq "a fetched patch keeps the time of the first run that held it" \
    "$(marker simplify)" "✓"

# A corrupt index makes git status fail, and an empty status must not read as a
# clean tree.
BROKEN_INDEX=$(new_repo broken-index)
commit_at "$BROKEN_INDEX" "2026-08-27T13:00:00Z" "first"
printf 'not an index' > "${BROKEN_INDEX}/.git/index"
run_reader "$BROKEN_INDEX"
check "a failed git status fails the report" test "$READER_STATUS" -ne 0
check "the failure names the working tree" grep -q "working tree" "$ERR_FILE"

summary
[[ "${failures}" -eq 0 ]]
