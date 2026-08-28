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

mkdir -p "$FAKE_HOME" "$LOG_DIR"

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
        HOME="$FAKE_HOME" TZ=UTC GH_TOKEN="" GITHUB_TOKEN="" "$READER" "$@"
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
check_eq "a step whose last run precedes its own commit is fresh" \
    "$(marker commit)" "✓"
check_eq "a step followed by an earlier step's commit is stale" \
    "$(marker create-pr)" "⚠"
check_eq "a step that is not due yet is neither missing nor stale" \
    "$(marker ci-monitor)" "·"

check "the header names the branch at HEAD" \
    out_has "Branch haacked/breadcrumbs @ ${PREVIEW_HEAD}"
check "a committing step shows the commit it produced, not its invocation sha" \
    contains "$(row commit)" "@ ${PREVIEW_HEAD}"
check "a non-committing step shows its invocation sha" \
    contains "$(row simplify)" "@ ${PREVIEW_MID}"
check "a stale row says why" contains "$(row create-pr)" "(stale, commits since)"
check "the outstanding steps are summarised" \
    out_has "2 steps outstanding: create-pr, review-code"

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
    printf '  ✓ commit              14:09  @ %s\n' "$PREVIEW_HEAD"
    printf '  ⚠ create-pr           13:40  @ %s (stale, commits since)\n' "$PREVIEW_MID"
    printf '  ✗ review-code         never run\n'
    printf '  · address-pr-reviews  not yet run\n'
    printf '  · ci-monitor          not yet run\n'
    printf '\n'
    printf '2 steps outstanding: create-pr, review-code\n'
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
check "commit shows the commit it produced" \
    contains "$(row commit)" "@ ${DONE_HEAD}"

# /go Step 2 seeds a review step only from a "fresh" row in this payload, so the
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
run_reader "$DONE"

check_eq "an unlogged commit still exits 0" "$READER_STATUS" "0"
check "an unlogged commit makes something stale" out_has "⚠"
check_eq "an unlogged commit staled simplify" "$(marker simplify)" "⚠"
check_eq "an unlogged commit staled commit" "$(marker commit)" "⚠"
check_eq "an unlogged commit staled create-pr" "$(marker create-pr)" "⚠"
check_eq "an unlogged commit staled review-code" "$(marker review-code)" "⚠"

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

summary
[[ "${failures}" -eq 0 ]]
