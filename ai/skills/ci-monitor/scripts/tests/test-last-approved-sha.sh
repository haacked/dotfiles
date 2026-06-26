#!/usr/bin/env bash
# Tests for last-approved-sha.jq, the prior-approval baseline selection.
#
# This pick is security-critical: it is the sha the auto-approve verdict trusts
# as "already reviewed". A wrong pick can only fail closed (signatures won't
# match), but it must never silently select a run from a different fork or a
# still-gated run.
#
# Usage: test-last-approved-sha.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SELECT_JQ="${SCRIPT_DIR}/../helpers/last-approved-sha.jq"

passes=0
failures=0

# run '<fork>' '<runs json>' -> prints the selected head_sha
run() {
    echo "$2" | jq -r --arg fork "$1" -f "${SELECT_JQ}"
}

assert_sha() {
    local description="$1" fork="$2" runs="$3" expected="$4"
    local actual
    actual=$(run "${fork}" "${runs}")
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

run_obj() {
    # status conclusion fork_owner head_sha
    jq -n --arg s "$1" --arg c "$2" --arg f "$3" --arg h "$4" \
        '{status: $s, conclusion: $c, head_repository: {owner: {login: $f}}, head_sha: $h}'
}

# Newest-first ordering: most recent ran-state run wins.
ordered=$(jq -n \
    --argjson a "$(run_obj completed success contributor newsha)" \
    --argjson b "$(run_obj completed success contributor oldsha)" \
    '{workflow_runs: [$a, $b]}')
assert_sha "picks newest ran run" "contributor" "${ordered}" "newsha"

# A still-gated run (conclusion action_required) is not an approved baseline.
gated_then_ran=$(jq -n \
    --argjson g "$(run_obj completed action_required contributor gatedsha)" \
    --argjson r "$(run_obj completed success contributor ransha)" \
    '{workflow_runs: [$g, $r]}')
assert_sha "skips still-gated run, picks the one that ran" "contributor" "${gated_then_ran}" "ransha"

# A same-named branch on a different fork must not be selected.
other_fork=$(jq -n \
    --argjson o "$(run_obj completed success attacker theirsha)" \
    --argjson m "$(run_obj completed success contributor mysha)" \
    '{workflow_runs: [$o, $m]}')
assert_sha "ignores same-named branch from another fork" "contributor" "${other_fork}" "mysha"

# An in-progress run (approved, still running) counts as a ran baseline.
in_progress=$(jq -n \
    --argjson p "$(run_obj in_progress null contributor runningsha)" \
    '{workflow_runs: [$p]}')
assert_sha "counts in-progress (approved) run" "contributor" "${in_progress}" "runningsha"

# No matching run -> empty string (verdict then fails closed).
none=$(jq -n --argjson g "$(run_obj completed action_required contributor onlygated)" '{workflow_runs: [$g]}')
assert_sha "no prior ran run -> empty" "contributor" "${none}" ""

# Empty payload -> empty string.
assert_sha "empty workflow_runs -> empty" "contributor" '{"workflow_runs": []}' ""

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
