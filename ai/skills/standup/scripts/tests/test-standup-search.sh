#!/usr/bin/env bash
# Tests for standup-search.sh.
#
# Usage: test-standup-search.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEARCH="${SCRIPT_DIR}/../standup-search.sh"

TESTTMP="$(mktemp -d)"
trap 'rm -rf "${TESTTMP}"' EXIT

# The stub answers like `gh api search/issues`, including its per_page,
# --paginate, and --slurp handling. It matches STUB_TOTAL PRs and returns
# STUB_RETURNED of them (default all). STUB_INCOMPLETE_PAGE sets
# incomplete_results on one zero-based page. STUB_FAIL makes the call fail.
mkdir -p "${TESTTMP}/bin"
cat > "${TESTTMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "${STUB_LOG}"
if [[ "${STUB_FAIL:-0}" -ne 0 ]]; then
    echo '{"message":"Bad credentials","status":"401"}'
    exit 1
fi
per_page=30 paginate=false slurp=false
for arg in "$@"; do
    case "${arg}" in
        per_page=*) per_page="${arg#per_page=}" ;;
        --paginate) paginate=true ;;
        --slurp) slurp=true ;;
    esac
done
total="${STUB_TOTAL}"
available="${STUB_RETURNED:-${total}}"
pages=1
if [[ "${paginate}" == true ]] && ((available > per_page)); then
    pages=$(((available + per_page - 1) / per_page))
fi
jq -n --argjson total "${total}" --argjson available "${available}" \
    --argjson per "${per_page}" --argjson pages "${pages}" \
    --argjson incomplete_page "${STUB_INCOMPLETE_PAGE:--1}" --argjson slurp "${slurp}" '
    [range(0; $pages) as $p | {
        total_count: $total,
        incomplete_results: ($p == $incomplete_page),
        items: [range($p * $per; [($p + 1) * $per, $available] | min) | {
            number: (. + 1),
            title: "PR \(. + 1)",
            html_url: "https://github.com/PostHog/posthog/pull/\(. + 1)",
            repository_url: "https://api.github.com/repos/PostHog/posthog",
            user: {login: "posthog[bot]"},
            draft: false,
            updated_at: "2026-10-22T10:00:00Z",
            pull_request: {merged_at: "2026-10-22T11:00:00Z"}
        }]
    }] | if $slurp then . else .[] end'
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

# search <env assignment>... -> runs the script with the stub configured. It
# sets rc, out, and err.
search() {
    : > "${STUB_LOG}"
    rc=0
    out="$(env "$@" "${SEARCH}" "author:haacked is:merged" 2> "${TESTTMP}/err")" || rc=$?
    err="$(cat "${TESTTMP}/err")"
}

# assert_refused <description> <stderr fragment> -> the last search failed,
# printed no PRs, and named the fragment on stderr.
assert_refused() {
    assert "$1 fails" test "${rc}" -ne 0
    assert "$1 prints no PRs" test -z "${out}"
    assert "$1 says why" grep -qF -- "$2" <<<"${err}"
}

# 250 matches fill three pages at 100 per page.
search STUB_TOTAL=250
assert "a search across three pages succeeds" test "${rc}" -eq 0
assert "a search across three pages prints PRs 1 to 250 once each" \
    test "$(jq -s 'map(.number) == [range(1; 251)]' <<<"${out}")" = true

assert "each PR is projected to the fields the skill reads" test "$(head -1 <<<"${out}")" = \
    '{"number":1,"title":"PR 1","url":"https://github.com/PostHog/posthog/pull/1","repo":"PostHog/posthog","author":"posthog[bot]","draft":false,"updated_at":"2026-10-22T10:00:00Z","merged_at":"2026-10-22T11:00:00Z"}'

assert "the query is passed as q" grep -qxF -- "q=author:haacked is:merged" "${STUB_LOG}"
assert "the search asks for 100 results per page" grep -qxF -- "per_page=100" "${STUB_LOG}"

search STUB_TOTAL=0
assert "an empty search succeeds" test "${rc}" -eq 0
assert "an empty search prints nothing" test -z "${out}"

# GitHub returns fewer items than it counted.
search STUB_TOTAL=45 STUB_RETURNED=30
assert_refused "a short read" "30 of 45"

# GitHub never returns more than 1,000 results for one query.
search STUB_TOTAL=1200 STUB_RETURNED=1000
assert_refused "a match over 1,000 results" "1000 of 1200"

# A search that timed out on GitHub's side can return a list whose length
# matches its count. Only incomplete_results shows the gap.
search STUB_TOTAL=10 STUB_INCOMPLETE_PAGE=0
assert_refused "an incomplete search" "incomplete_results: true"

# Only the second of three pages timed out.
search STUB_TOTAL=250 STUB_INCOMPLETE_PAGE=1
assert_refused "a search with one incomplete middle page" "incomplete_results: true"

search STUB_TOTAL=5 STUB_FAIL=1
assert "a failed gh call fails" test "${rc}" -ne 0
assert "a failed gh call prints no PRs" test -z "${out}"

rc=0
"${SEARCH}" > /dev/null 2>&1 || rc=$?
assert "a missing query is a usage error" test "${rc}" -eq 64

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
