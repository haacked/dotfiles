#!/usr/bin/env bash
# Tests for checks-rollup.jq, which reimplements gh's `pr checks` bucketing
# (pass/fail/pending/skipping/cancel) against the raw `statusCheckRollup`
# union of CheckRun and StatusContext nodes.
#
# The property under test is byte-for-byte parity with what
# `gh pr checks --json name,state,bucket,link,workflow` used to return, since
# ci-check-status.sh's own logic downstream of this (total/passed/pending
# counts, the action_required exclusion, per-failure name/state/bucket/
# workflow/link) is unchanged and depends on that shape exactly.
#
# Usage: test-checks-rollup.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROLLUP_JQ="${SCRIPT_DIR}/../helpers/checks-rollup.jq"

passes=0
failures=0

# check_run <name> <workflow> <status> <conclusion> [<startedAt>] [<detailsUrl>]
check_run() {
    jq -c -n --arg name "$1" --arg wf "$2" --arg status "$3" --arg concl "$4" \
        --arg started "${5:-2026-09-01T00:00:00Z}" \
        --arg url "${6:-https://github.com/o/r/actions/runs/1/job/2}" '
        {__typename: "CheckRun", name: $name, workflowName: $wf, status: $status,
         conclusion: $concl, startedAt: $started, completedAt: $started, detailsUrl: $url}'
}

# status_context <context> <state> [<startedAt>] [<targetUrl>]
status_context() {
    jq -c -n --arg ctx "$1" --arg state "$2" \
        --arg started "${3:-2026-09-01T00:00:00Z}" \
        --arg url "${4:-https://ci.example.com/build/1}" '
        {__typename: "StatusContext", context: $ctx, state: $state,
         startedAt: $started, targetUrl: $url}'
}

# rollup <check json...> -> a JSON array of the given check objects
rollup() {
    printf '%s\n' "$@" | jq -s -c '.'
}

# run_rollup <rollup json> -> the jq program's output array
run_rollup() {
    jq -n --argjson r "$1" '$r' | jq -f "${ROLLUP_JQ}"
}

# assert_field <description> <rollup json> <check name> <field> <expected>
#
# Looks the check up by name rather than array position: checks-rollup.jq
# sorts by startedAt descending, and nothing downstream depends on order, so
# pinning position would test an accident of the sort instead of the mapping.
assert_field() {
    local description="$1" input="$2" name="$3" field="$4" expected="$5"
    local actual
    actual=$(run_rollup "${input}" | jq -r --arg n "${name}" --arg f "${field}" \
        'map(select(.name == $n)) | first | .[$f]')
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  ${name}.${field}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

# assert_length <description> <rollup json> <expected>
assert_length() {
    local description="$1" input="$2" expected="$3"
    local actual
    actual=$(run_rollup "${input}" | jq 'length')
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  length: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

# ── All passed ───────────────────────────────────────────────────────────────

ALL_PASSED=$(rollup \
    "$(check_run "lint" "CI" "COMPLETED" "SUCCESS")" \
    "$(check_run "test" "CI" "COMPLETED" "SUCCESS")" \
    "$(status_context "vercel/deployment" "SUCCESS")")

assert_length "all-passed keeps every check" "${ALL_PASSED}" "3"
assert_field "all-passed: check-run bucket" "${ALL_PASSED}" "lint" "bucket" "pass"
assert_field "all-passed: check-run link is its detailsUrl" \
    "${ALL_PASSED}" "lint" "link" "https://github.com/o/r/actions/runs/1/job/2"
assert_field "all-passed: status-context bucket" "${ALL_PASSED}" "vercel/deployment" "bucket" "pass"
assert_field "all-passed: status-context link falls back to targetUrl" \
    "${ALL_PASSED}" "vercel/deployment" "link" "https://ci.example.com/build/1"
assert_field "all-passed: status-context workflow is empty, not null" \
    "${ALL_PASSED}" "vercel/deployment" "workflow" ""

# ── One failure ──────────────────────────────────────────────────────────────

ONE_FAILURE=$(rollup \
    "$(check_run "lint" "CI" "COMPLETED" "SUCCESS")" \
    "$(check_run "test" "CI" "COMPLETED" "FAILURE")")

assert_field "one-failure: failing check bucket" "${ONE_FAILURE}" "test" "bucket" "fail"
assert_field "one-failure: failing check state" "${ONE_FAILURE}" "test" "state" "FAILURE"
assert_field "one-failure: passing check unaffected" "${ONE_FAILURE}" "lint" "bucket" "pass"

# ── One pending ──────────────────────────────────────────────────────────────

ONE_PENDING=$(rollup \
    "$(check_run "lint" "CI" "COMPLETED" "SUCCESS")" \
    "$(check_run "test" "CI" "IN_PROGRESS" "")")

assert_field "one-pending: in-progress check buckets pending" "${ONE_PENDING}" "test" "bucket" "pending"
assert_field "one-pending: in-progress check state is its status" "${ONE_PENDING}" "test" "state" "IN_PROGRESS"

QUEUED=$(rollup "$(check_run "build" "CI" "QUEUED" "")")
assert_field "queued check buckets pending" "${QUEUED}" "build" "bucket" "pending"

WAITING=$(rollup "$(check_run "deploy-gate" "CI" "WAITING" "")")
assert_field "waiting check buckets pending" "${WAITING}" "deploy-gate" "bucket" "pending"

STATUS_PENDING=$(rollup "$(status_context "vercel/deployment" "PENDING")")
assert_field "pending status context buckets pending" "${STATUS_PENDING}" "vercel/deployment" "bucket" "pending"

STATUS_EXPECTED=$(rollup "$(status_context "vercel/deployment" "EXPECTED")")
assert_field "expected status context buckets pending" "${STATUS_EXPECTED}" "vercel/deployment" "bucket" "pending"

# ── Action required (fork-approval-gated) ────────────────────────────────────
# Bucket "fail" the same as any other failure - ci-check-status.sh excludes it
# from real_fail_checks by state, not by bucket.

ACTION_REQUIRED=$(rollup \
    "$(check_run "lint" "CI" "COMPLETED" "SUCCESS")" \
    "$(check_run "e2e" "CI" "COMPLETED" "ACTION_REQUIRED")")

assert_field "action_required buckets fail" "${ACTION_REQUIRED}" "e2e" "bucket" "fail"
assert_field "action_required keeps its state distinguishable from a real failure" \
    "${ACTION_REQUIRED}" "e2e" "state" "ACTION_REQUIRED"

# ── A mix ────────────────────────────────────────────────────────────────────

MIX=$(rollup \
    "$(check_run "lint" "CI" "COMPLETED" "SUCCESS")" \
    "$(check_run "test" "CI" "COMPLETED" "FAILURE")" \
    "$(check_run "e2e" "CI" "COMPLETED" "ACTION_REQUIRED")" \
    "$(check_run "build" "CI" "IN_PROGRESS" "")" \
    "$(check_run "docs" "CI" "COMPLETED" "SKIPPED")" \
    "$(check_run "old-attempt" "CI" "COMPLETED" "CANCELLED")" \
    "$(status_context "vercel/deployment" "SUCCESS")")

assert_length "mix keeps every distinct check" "${MIX}" "7"
assert_field "mix: pass" "${MIX}" "lint" "bucket" "pass"
assert_field "mix: fail" "${MIX}" "test" "bucket" "fail"
assert_field "mix: action_required also fails" "${MIX}" "e2e" "bucket" "fail"
assert_field "mix: pending" "${MIX}" "build" "bucket" "pending"
assert_field "mix: skipped -> skipping" "${MIX}" "docs" "bucket" "skipping"
assert_field "mix: cancelled -> cancel" "${MIX}" "old-attempt" "bucket" "cancel"
assert_field "mix: status context pass" "${MIX}" "vercel/deployment" "bucket" "pass"

NEUTRAL=$(rollup "$(check_run "advisory" "CI" "COMPLETED" "NEUTRAL")")
assert_field "neutral conclusion -> skipping" "${NEUTRAL}" "advisory" "bucket" "skipping"

TIMED_OUT=$(rollup "$(check_run "flaky" "CI" "COMPLETED" "TIMED_OUT")")
assert_field "timed_out conclusion -> fail" "${TIMED_OUT}" "flaky" "bucket" "fail"

ERROR_STATUS=$(rollup "$(status_context "legacy-ci" "ERROR")")
assert_field "error status context -> fail" "${ERROR_STATUS}" "legacy-ci" "bucket" "fail"

# ── Deduplication ────────────────────────────────────────────────────────────
# A rerun leaves both the old and new CheckRun nodes for the same job in the
# rollup; gh's own `pr checks` keeps only the most recent. Without this, a
# rerun that turns a failure into a pass would leave the stale failure
# alongside it and ci-monitor's flaky-rerun loop would never see all_passed.

RERUN_STALE_FIRST=$(rollup \
    "$(check_run "test" "CI" "COMPLETED" "FAILURE" "2026-09-01T00:00:00Z")" \
    "$(check_run "test" "CI" "COMPLETED" "SUCCESS" "2026-09-01T00:05:00Z")")
assert_length "rerun collapses to one entry regardless of input order" "${RERUN_STALE_FIRST}" "1"
assert_field "rerun keeps the most recent run's outcome" "${RERUN_STALE_FIRST}" "test" "bucket" "pass"

RERUN_NEW_FIRST=$(rollup \
    "$(check_run "test" "CI" "COMPLETED" "SUCCESS" "2026-09-01T00:05:00Z")" \
    "$(check_run "test" "CI" "COMPLETED" "FAILURE" "2026-09-01T00:00:00Z")")
assert_length "rerun collapses regardless of which came first in the input" "${RERUN_NEW_FIRST}" "1"
assert_field "rerun sorts by startedAt, not input order" "${RERUN_NEW_FIRST}" "test" "bucket" "pass"

DEDUP_BY_CONTEXT=$(rollup \
    "$(status_context "vercel/deployment" "PENDING" "2026-09-01T00:00:00Z")" \
    "$(status_context "vercel/deployment" "SUCCESS" "2026-09-01T00:05:00Z")")
assert_length "status contexts dedup by context" "${DEDUP_BY_CONTEXT}" "1"
assert_field "status context dedup keeps the latest state" "${DEDUP_BY_CONTEXT}" "vercel/deployment" "bucket" "pass"

DISTINCT_WORKFLOWS=$(rollup \
    "$(check_run "test" "CI" "COMPLETED" "SUCCESS")" \
    "$(check_run "test" "Nightly" "COMPLETED" "SUCCESS")")
assert_length "same name, different workflow, is not a duplicate" "${DISTINCT_WORKFLOWS}" "2"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
