#!/usr/bin/env bash
# Tests for approval-safety.jq, the pure auto-approve verdict.
#
# Feeds fixtures straight into the jq decision program and asserts on `safe`.
# The property under test is "false negatives are safe": every uncertain or
# changed input must yield safe:false; only an unchanged contributor patch may
# yield safe:true.
#
# Usage: test-approval-safety.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DECISION_JQ="${SCRIPT_DIR}/../helpers/approval-safety.jq"

passes=0
failures=0

# decide '<input json>' -> prints the `safe` boolean
decide() {
    jq -n "$1" | jq -f "${DECISION_JQ}" | jq -r '.safe'
}

assert_safe() {
    local description="$1" input="$2" expected="$3"
    local actual
    actual=$(decide "${input}")
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  expected safe=${expected}, got safe=${actual}"
        echo "  reason: $(jq -n "${input}" | jq -f "${DECISION_JQ}" | jq -r '.reason')"
        failures=$((failures + 1))
    fi
}

# A contributor patch: one file with a fixed blob sha.
patch_a='{files: [{filename: "src/app.rs", status: "modified", sha: "aaa111", previous_filename: null}]}'
# Same files, one blob sha changed: the contributor edited something.
patch_a_changed='{files: [{filename: "src/app.rs", status: "modified", sha: "bbb222", previous_filename: null}]}'
gated_pr='[{event: "pull_request", run_id: 1, workflow: "CI"}]'
gated_target='[{event: "pull_request_target", run_id: 2, workflow: "Label"}]'

# 1. Pure base-branch merge, no file overlap -> contributor patch identical -> true
assert_safe "pure base-sync, patch unchanged" \
    "{last_approved_sha: \"old\", current_head_sha: \"new\", gated_runs: ${gated_pr}, compare_then: ${patch_a}, compare_now: ${patch_a}}" \
    "true"

# 2. A new contributor commit changed a blob -> false
assert_safe "contributor changed a file -> false" \
    "{last_approved_sha: \"old\", current_head_sha: \"new\", gated_runs: ${gated_pr}, compare_then: ${patch_a}, compare_now: ${patch_a_changed}}" \
    "false"

# 3. Merge touched a file the contributor also changed (blob differs) -> fail closed
#    (Modeled as the file dropping out of the "now" diff: file set differs.)
assert_safe "overlap changes file set -> false" \
    "{last_approved_sha: \"old\", current_head_sha: \"new\", gated_runs: ${gated_pr}, compare_then: ${patch_a}, compare_now: {files: []}}" \
    "false"

# 4. Any gated run is pull_request_target -> false
assert_safe "pull_request_target gated -> false" \
    "{last_approved_sha: \"old\", current_head_sha: \"new\", gated_runs: ${gated_target}, compare_then: ${patch_a}, compare_now: ${patch_a}}" \
    "false"

# 5. compare truncation (>=300 files) -> false
big=$(jq -n '{files: [range(300) | {filename: ("f" + (tostring)), status: "modified", sha: "x", previous_filename: null}]}')
assert_safe "truncated compare (>=300 files) -> false" \
    "{last_approved_sha: \"old\", current_head_sha: \"new\", gated_runs: ${gated_pr}, compare_then: ${big}, compare_now: ${big}}" \
    "false"

# 6. No prior approved run -> false
assert_safe "no prior approval -> false" \
    "{last_approved_sha: \"\", current_head_sha: \"new\", gated_runs: ${gated_pr}, compare_then: ${patch_a}, compare_now: ${patch_a}}" \
    "false"

# 7. Force-push that only rebases onto newer master -> contributor patch identical -> true
assert_safe "rebase-only force-push -> true" \
    "{last_approved_sha: \"old\", current_head_sha: \"rebased\", gated_runs: ${gated_pr}, compare_then: ${patch_a}, compare_now: ${patch_a}}" \
    "true"

# 8. .github/ workflow change must NOT be ignored -> false
gh_then='{files: [{filename: ".github/workflows/ci.yml", status: "modified", sha: "w1", previous_filename: null}]}'
gh_now='{files: [{filename: ".github/workflows/ci.yml", status: "modified", sha: "w2", previous_filename: null}]}'
assert_safe "workflow file change -> false" \
    "{last_approved_sha: \"old\", current_head_sha: \"new\", gated_runs: ${gated_pr}, compare_then: ${gh_then}, compare_now: ${gh_now}}" \
    "false"

# 9. Head identical to last approved sha (re-gated same sha, e.g. new base workflow) -> true
assert_safe "head == last approved sha -> true" \
    "{last_approved_sha: \"same\", current_head_sha: \"same\", gated_runs: ${gated_pr}, compare_then: {}, compare_now: {}}" \
    "true"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
