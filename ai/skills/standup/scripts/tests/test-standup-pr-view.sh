#!/usr/bin/env bash
# Tests for standup-pr-view.sh.
#
# Usage: test-standup-pr-view.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOOKUP="${SCRIPT_DIR}/../standup-pr-view.sh"

TESTTMP="$(mktemp -d)"
trap 'rm -rf "${TESTTMP}"' EXIT

# The stub answers `gh pr view <url> --json <fields> --jq <filter>` with
# "<url> <fields> <filter>". It fails for the URL in STUB_FAIL_URL.
mkdir -p "${TESTTMP}/bin"
cat > "${TESTTMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
url="$3" fields="$5" filter="$7"
if [[ "${url}" == "${STUB_FAIL_URL:-}" ]]; then
    echo "GraphQL: Could not resolve to a PullRequest." >&2
    exit 1
fi
echo "${url} ${fields} ${filter}"
STUB
chmod +x "${TESTTMP}/bin/gh"
export PATH="${TESTTMP}/bin:${PATH}"

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

# lookup <failing url> <args>... -> runs the script with the stub configured.
# It sets rc, out, and err.
lookup() {
    local fail_url="$1"
    shift
    rc=0
    out="$(STUB_FAIL_URL="${fail_url}" "${LOOKUP}" "$@" 2> "${TESTTMP}/err")" || rc=$?
    err="$(cat "${TESTTMP}/err")"
}

tab=$'\t'
pr1="https://github.com/PostHog/posthog/pull/1"
pr2="https://github.com/PostHog/posthog-js/pull/2"
pr3="https://github.com/PostHog/posthog/pull/3"

# The filter has a space, so a split argument would change the row.
lookup "" state,mergedAt '[.state] | @tsv' "${pr1}" "${pr2}"
assert "a lookup where every PR resolves succeeds" test "${rc}" -eq 0
assert "a lookup prints one row per PR, keyed by its URL" test "${out}" = \
    "${pr1}${tab}${pr1} state,mergedAt [.state] | @tsv
${pr2}${tab}${pr2} state,mergedAt [.state] | @tsv"

lookup "${pr2}" reviews '.reviews' "${pr1}" "${pr2}" "${pr3}"
assert "a failed lookup fails the script" test "${rc}" -ne 0
assert "a failed lookup names the PR" grep -qF "gh pr view failed for ${pr2}" <<<"${err}"
assert "a failed lookup skips only that PR's row" test "${out}" = \
    "${pr1}${tab}${pr1} reviews .reviews
${pr3}${tab}${pr3} reviews .reviews"

rc=0
"${LOOKUP}" state '.state' > /dev/null 2>&1 || rc=$?
assert "a lookup with no PRs is a usage error" test "${rc}" -eq 64

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
