#!/usr/bin/env bash
# Tests for standup-pr-view.sh.
#
# Usage: test-standup-pr-view.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOKUP="${SCRIPT_DIR}/../standup-pr-view.sh"

TESTTMP="$(mktemp -d)"
trap 'rm -rf "${TESTTMP}"' EXIT

# The stub answers `gh pr view <number> --repo <repo> --json <fields> --jq
# <filter>` with "<repo>#<number> <fields> <filter>". It fails for the PR
# numbers listed in STUB_FAIL_NUMBERS.
mkdir -p "${TESTTMP}/bin"
cat > "${TESTTMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_LOG}"
num="$3" repo="$5" fields="$7" filter="$9"
for failing in ${STUB_FAIL_NUMBERS:-}; do
    if [[ "${num}" == "${failing}" ]]; then
        echo "GraphQL: Could not resolve to a PullRequest with the number of ${num}." >&2
        exit 1
    fi
done
echo "${repo}#${num} ${fields} ${filter}"
STUB
chmod +x "${TESTTMP}/bin/gh"
export PATH="${TESTTMP}/bin:${PATH}"
export STUB_LOG="${TESTTMP}/gh-calls"

passes=0
failures=0

assert() {
    local description="$1"
    shift
    if "$@"; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        failures=$((failures + 1))
    fi
}

# lookup <env assignment>... -- <args>... -> runs the script with the stub
# configured. It sets rc, out, and err.
lookup() {
    local env_args=()
    while [[ "$1" != "--" ]]; do
        env_args+=("$1")
        shift
    done
    shift
    : > "${STUB_LOG}"
    rc=0
    out="$(env "${env_args[@]}" "${LOOKUP}" "$@" 2> "${TESTTMP}/err")" || rc=$?
    err="$(cat "${TESTTMP}/err")"
}

tab=$'\t'

lookup STUB_FAIL_NUMBERS= -- state,mergedAt '.state' "PostHog/posthog#1" "PostHog/posthog-js#2"
assert "a lookup where every PR resolves succeeds" test "${rc}" -eq 0
assert "a lookup prints one row per PR, keyed by the PR" test "${out}" = \
    "PostHog/posthog#1${tab}PostHog/posthog#1 state,mergedAt .state
PostHog/posthog-js#2${tab}PostHog/posthog-js#2 state,mergedAt .state"
assert "the filter reaches gh as one argument" grep -qxF -- ".state" "${STUB_LOG}"

lookup STUB_FAIL_NUMBERS=2 -- reviews '.reviews' "PostHog/posthog#1" "PostHog/posthog#2" "PostHog/posthog#3"
assert "a failed lookup fails the script" test "${rc}" -ne 0
assert "a failed lookup names the PR" grep -qF "gh pr view failed for PostHog/posthog#2" <<<"${err}"
assert "a failed lookup prints no row for that PR" test "$(grep -c "PostHog/posthog#2" <<<"${out}")" -eq 0
assert "the PRs after a failed lookup still print" grep -qF "PostHog/posthog#3${tab}" <<<"${out}"

rc=0
"${LOOKUP}" state '.state' > /dev/null 2>&1 || rc=$?
assert "a lookup with no PRs is a usage error" test "${rc}" -eq 64

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
