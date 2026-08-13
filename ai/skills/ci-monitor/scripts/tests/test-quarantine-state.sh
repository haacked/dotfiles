#!/usr/bin/env bash
# Tests for quarantine-state.jq, the Trunk Test Analytics badge parse.
#
# The counts decide how a merge-queue eviction is reported (unquarantined
# flake vs quarantine gap vs not test-level), so the parse must read a real
# comment body exactly and fail closed - readable:false, never a guessed
# count - on anything else.
#
# Usage: test-quarantine-state.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATE_JQ="${SCRIPT_DIR}/../helpers/quarantine-state.jq"

passes=0
failures=0

# assert_field '<desc>' '<body|null json>' <field> <expected>
assert_field() {
    local description="$1" body_json="$2" field="$3" expected="$4"
    local actual
    actual=$(jq -n --argjson b "${body_json}" '{body: $b, updated_at: "2026-08-03T13:00:00Z"}' \
        | jq -f "${STATE_JQ}" \
        | jq -r --arg f "${field}" 'getpath($f | split(".")) | tostring')
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  ${field}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

# A real analytics comment body, observed live on PostHog/posthog#77004. The
# leading tests badge (`112869_tests-fc41fff3`) pins that its digits never
# leak into the failed/quarantined counts.
REAL='<!-- Trunk Test Analytics -->


[![Static Badge](https://raster.shields.io/badge/112869_tests-fc41fff3-purple)](https://app.trunk.io/posthog-inc/flaky-tests/pr/77004?repo=PostHog/posthog&commitHash=fc41fff33b87af7626762acba2ec5ed29a68cd0d&utm_source=gh-comment) &ensp; [![Static Badge](https://raster.shields.io/badge/0-failed-crimson)](https://app.trunk.io/posthog-inc/flaky-tests/pr/77004?repo=PostHog/posthog&commitHash=fc41fff33b87af7626762acba2ec5ed29a68cd0d&utm_source=gh-comment&runConclusion=FAILURE) &ensp; [![Static Badge](https://raster.shields.io/badge/0-quarantined-yellow)](https://app.trunk.io/posthog-inc/flaky-tests/pr/77004?repo=PostHog/posthog&commitHash=fc41fff33b87af7626762acba2ec5ed29a68cd0d&utm_source=gh-comment&runConclusion=QUARANTINED)


<sub>

[View Full Report ↗︎](https://app.trunk.io/posthog-inc/flaky-tests/pr/77004?repo=PostHog/posthog&commitHash=fc41fff33b87af7626762acba2ec5ed29a68cd0d&utm_source=gh-comment) ⋅ [Docs](https://docs.trunk.io/flaky-tests?utm_source=gh-comment)

</sub>'
REAL_JSON=$(jq -n --arg b "${REAL}" '$b')

assert_field "real body is readable" "${REAL_JSON}" readable "true"
assert_field "real body: zero failed" "${REAL_JSON}" failed "0"
assert_field "real body: zero quarantined" "${REAL_JSON}" quarantined "0"
assert_field "real body: commit from the badge links" "${REAL_JSON}" \
    commit "fc41fff33b87af7626762acba2ec5ed29a68cd0d"

# Non-zero counts read as numbers.
COUNTS=$(jq -n '"x badge/3-failed-crimson y badge/12-quarantined-yellow z"')
assert_field "failed count parses" "${COUNTS}" failed "3"
assert_field "quarantined count parses" "${COUNTS}" quarantined "12"
assert_field "no commit link -> null commit" "${COUNTS}" commit "null"

# Fail closed: both badges are required for a reading.
assert_field "marker without badges -> unreadable" \
    "$(jq -n '"<!-- Trunk Test Analytics --> nothing to see"')" readable "false"
assert_field "marker without badges -> no count" \
    "$(jq -n '"<!-- Trunk Test Analytics --> nothing to see"')" failed "null"
assert_field "only one badge -> unreadable" \
    "$(jq -n '"badge/4-failed-crimson"')" readable "false"
assert_field "missing body -> unreadable" "null" readable "false"

assert_field "updated_at passes through" "${REAL_JSON}" \
    updated_at "2026-08-03T13:00:00Z"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
