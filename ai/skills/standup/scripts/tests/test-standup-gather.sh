#!/usr/bin/env bash
# Tests for standup-gather.sh.
#
# Usage: test-standup-gather.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATHER="${SCRIPT_DIR}/../standup-gather.sh"
SAVE="${SCRIPT_DIR}/../standup-save.sh"
DATES="${SCRIPT_DIR}/../standup-dates.sh"

TESTTMP="$(mktemp -d)"
trap 'rm -rf "${TESTTMP}"' EXIT

# The stub logs each call's arguments one per line, followed by a "--" line.
#
# `gh api search/issues ... -f q=<query>` picks a fixture by the query's kind
# (authored, involves, reviewed, open) and returns it as one page, honoring
# --slurp. STUB_FAIL_SEARCH=<kind> fails that search. STUB_INCOMPLETE_SEARCH=<kind>
# marks that search's page incomplete.
#
# `gh pr view <url> --json <fields> --jq <filter>` projects the URL's fixture to
# the requested fields and runs the filter over it with real jq. A URL without
# a fixture fails, and so does the URL in STUB_FAIL_PR.
#
# `gh api orgs/PostHog/teams/team-feature-flags/members` returns the roster
# fixture, filtered by --jq when given. STUB_FAIL_ROSTER=1 fails it.
mkdir -p "${TESTTMP}/bin"
cat > "${TESTTMP}/bin/gh" <<'STUB'
#!/usr/bin/env bash
{ printf '%s\n' "$@"; echo "--"; } >> "${STUB_LOG}"

flag_value() {
    local name="$1"
    shift
    while [[ $# -gt 0 ]]; do
        if [[ "$1" == "${name}" ]]; then
            echo "$2"
            return
        fi
        shift
    done
}

if [[ "$1" == api && "$2" == search/issues ]]; then
    q="" slurp=false
    for arg in "$@"; do
        case "${arg}" in
            q=*) q="${arg#q=}" ;;
            --slurp) slurp=true ;;
        esac
    done
    case "${q}" in
        *is:open*) kind=open ;;
        *reviewed-by:haacked*) kind=reviewed ;;
        *involves:haacked*) kind=involves ;;
        *author:haacked*is:merged*) kind=authored ;;
        *) echo "unexpected search: ${q}" >&2; exit 1 ;;
    esac
    if [[ "${STUB_FAIL_SEARCH:-}" == "${kind}" ]]; then
        echo '{"message":"Bad credentials","status":"401"}'
        exit 1
    fi
    fixture="${STUB_DIR}/search-${kind}.json"
    [[ -f "${fixture}" ]] || fixture=/dev/null
    jq -s --argjson slurp "${slurp}" --argjson incomplete \
        "$([[ "${STUB_INCOMPLETE_SEARCH:-}" == "${kind}" ]] && echo true || echo false)" '
        (.[0] // []) as $items
        | [{total_count: ($items | length), incomplete_results: $incomplete, items: $items}]
        | if $slurp then . else .[] end' "${fixture}"
    exit 0
fi

if [[ "$1" == pr && "$2" == view ]]; then
    url="$3"
    fields="$(flag_value --json "$@")"
    filter="$(flag_value --jq "$@")"
    fixture="${STUB_DIR}/pr/$(tr -c 'A-Za-z0-9\n' '_' <<<"${url}").json"
    if [[ "${url}" == "${STUB_FAIL_PR:-}" || ! -f "${fixture}" ]]; then
        echo "GraphQL: Could not resolve to a PullRequest." >&2
        exit 1
    fi
    jq --arg f "${fields}" '. as $o | reduce ($f | split(","))[] as $k ({}; .[$k] = $o[$k])' "${fixture}" \
        | jq -cr "${filter:-.}"
    exit
fi

if [[ "$1" == api && "$2" == orgs/*/teams/*/members ]]; then
    if [[ "${STUB_FAIL_ROSTER:-0}" -ne 0 ]]; then
        echo '{"message":"Not Found","status":"404"}'
        exit 1
    fi
    jq -cr "$(flag_value --jq "$@" || true)" "${STUB_DIR}/roster.json" 2>/dev/null \
        || jq -c . "${STUB_DIR}/roster.json"
    exit
fi

echo "unexpected gh call: $*" >&2
exit 1
STUB
chmod +x "${TESTTMP}/bin/gh"
export PATH="${TESTTMP}/bin:${PATH}"
export STUB_LOG="${TESTTMP}/gh-calls"
export STUB_DIR="${TESTTMP}/fixtures"
export HOME="${TESTTMP}/home"
unset XDG_CACHE_HOME
state_dir="${HOME}/.cache/standup"
archive_dir="${HOME}/dev/haacked/notes/PostHog/raw/standup"

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

reset_case() {
    rm -rf "${HOME}" "${STUB_DIR}"
    mkdir -p "${archive_dir}" "${STUB_DIR}/pr"
    echo '[{"login":"teammate"},{"login":"haacked"}]' > "${STUB_DIR}/roster.json"
    : > "${STUB_LOG}"
}

pr_url() {
    echo "https://github.com/$1/pull/$2"
}

# raw_item <number> <repo> <author> <draft> <merged_at or ""> [<updated_at>]
# -> one search result in the shape GitHub's search/issues returns.
raw_item() {
    jq -nc --argjson n "$1" --arg repo "$2" --arg author "$3" --argjson draft "$4" --arg merged "$5" \
        --arg updated "${6:-2026-11-03T10:00:00Z}" '{
        number: $n,
        title: "PR \($n)",
        html_url: "https://github.com/\($repo)/pull/\($n)",
        repository_url: "https://api.github.com/repos/\($repo)",
        user: {login: $author},
        draft: $draft,
        updated_at: $updated,
        pull_request: {merged_at: (if $merged == "" then null else $merged end)}
    }'
}

# search_fixture <kind> <raw item>...
search_fixture() {
    local kind="$1"
    shift
    printf '%s\n' "$@" | jq -s . > "${STUB_DIR}/search-${kind}.json"
}

# pr_fixture <url> <gh pr view JSON>
pr_fixture() {
    printf '%s\n' "$2" > "${STUB_DIR}/pr/$(tr -c 'A-Za-z0-9\n' '_' <<<"$1").json"
}

# verified_fixture <url> <merged by> <haacked's review state or ""> -> a PR
# merged by that login. Another reviewer always approves it, so only haacked's
# review decides whether it counts.
verified_fixture() {
    pr_fixture "$1" "$(jq -nc --arg by "$2" --arg state "$3" '{
        mergedBy: {login: $by},
        reviews: ([{author: {login: "someone"}, state: "APPROVED"}]
            + (if $state == "" then [] else [{author: {login: "haacked"}, state: $state}] end))
    }')"
}

state_fixture() {
    pr_fixture "$1" "$(jq -nc --arg state "$2" --arg merged "$3" \
        '{state: $state, mergedAt: (if $merged == "" then null else $merged end)}')"
}

# run_gather <last standup date> [env assignment]... -> sets rc and out.
run_gather() {
    local last="$1"
    shift
    : > "${STUB_LOG}"
    rc=0
    out="$(env "$@" "${GATHER}" "${last}" 2> /dev/null)" || rc=$?
}

query_ran() {
    grep -qxF -- "q=$1" "${STUB_LOG}"
}

roster_ran() {
    grep -qxF -- "orgs/PostHog/teams/team-feature-flags/members" "${STUB_LOG}"
}

# jq_out <filter> -> runs the filter over the last gather's stdout.
jq_out() {
    jq -c "$1" <<<"${out}"
}


pp="PostHog/posthog"
pjs="PostHog/posthog-js"

# setup_full -> a previous standup with carry-over PRs and every kind of PR the
# searches can return.
setup_full() {
    reset_case

    printf '%s\n' \
        "Working on:" \
        "- Stale ($(pr_url "${pp}" 999) - PR)" \
        > "${archive_dir}/2026-10-28.md"
    TZ=UTC touch -t 202610281500.00 "${archive_dir}/2026-10-28.md"

    printf '%s\n' \
        "Yesterday:" \
        "- Shipped ($(pr_url "${pp}" 900) - merged)" \
        "" \
        "Working on:" \
        "- Desc ($(pr_url "${pp}" 126045) - PR), more ($(pr_url "${pp}" 1) - draft)" \
        "- Other ($(pr_url "${pjs}" 77) - PR), merged elsewhere ($(pr_url "${pp}" 2) - PR)" \
        "- Tracked in https://github.com/PostHog/posthog/issues/5" \
        "" \
        "Side quests:" \
        "- Thing ($(pr_url "${pp}" 555) - PR)" \
        > "${archive_dir}/2026-10-30.md"
    TZ=UTC touch -t 202610301530.00 "${archive_dir}/2026-10-30.md"

    state_fixture "$(pr_url "${pp}" 126045)" MERGED "2026-10-31T09:00:00Z"
    state_fixture "$(pr_url "${pp}" 1)" OPEN ""
    state_fixture "$(pr_url "${pjs}" 77)" MERGED "2026-10-29T09:00:00Z"
    state_fixture "$(pr_url "${pp}" 2)" MERGED "2026-11-01T09:00:00Z"
    state_fixture "$(pr_url "${pp}" 900)" MERGED "2026-10-29T09:00:00Z"
    state_fixture "$(pr_url "${pp}" 555)" OPEN ""
    state_fixture "$(pr_url "${pp}" 999)" OPEN ""

    search_fixture authored \
        "$(raw_item 100 "${pp}" haacked false "2026-11-03T11:00:00Z")" \
        "$(raw_item 126045 "${pp}" haacked false "2026-10-31T09:00:00Z")"

    search_fixture involves \
        "$(raw_item 200 "${pp}" "posthog[bot]" false "2026-11-01T11:00:00Z")" \
        "$(raw_item 201 "${pp}" outsider false "2026-11-01T11:00:00Z")" \
        "$(raw_item 202 "${pp}" teammate false "2026-11-01T11:00:00Z")" \
        "$(raw_item 203 "${pp}" commenter false "2026-11-01T11:00:00Z")" \
        "$(raw_item 204 "${pjs}" trunked false "2026-11-01T11:00:00Z")" \
        "$(raw_item 205 "${pp}" bystander false "2026-11-01T11:00:00Z")"
    search_fixture reviewed \
        "$(raw_item 201 "${pp}" outsider false "2026-11-01T11:00:00Z")" \
        "$(raw_item 206 "${pp}" blocked false "2026-11-01T11:00:00Z")"

    verified_fixture "$(pr_url "${pp}" 200)" haacked ""
    verified_fixture "$(pr_url "${pp}" 201)" someone APPROVED
    verified_fixture "$(pr_url "${pp}" 202)" someone APPROVED
    verified_fixture "$(pr_url "${pp}" 203)" someone COMMENTED
    verified_fixture "$(pr_url "${pjs}" 204)" app/trunk-io APPROVED
    verified_fixture "$(pr_url "${pp}" 205)" someone ""
    verified_fixture "$(pr_url "${pp}" 206)" someone CHANGES_REQUESTED

    search_fixture open \
        "$(raw_item 300 "${pp}" haacked false "")" \
        "$(raw_item 301 "${pp}" haacked true "")" \
        "$(raw_item 302 "${pp}" haacked true "" "2026-10-20T10:00:00Z")"
    pr_fixture "$(pr_url "${pp}" 300)" '{"reviewRequests":[{"login":"alice"},{"login":"bob"}]}'
    pr_fixture "$(pr_url "${pp}" 301)" '{"reviewRequests":[{"login":"carol"}]}'
}

urls_of() {
    jq_out "[.$1[].url] | sort"
}

expect_urls() {
    jq -nc '$ARGS.positional | sort' --args "$@"
}

# A previous standup sets the cutoff, the carry-over, and the verified lists.

setup_full
run_gather "2026-11-02"
cutoff="2026-10-30T15:30:00Z"
assert "a gather succeeds" test "${rc}" -eq 0
assert "the cutoff is the previous notes' mtime" test "$(jq -r .cutoff <<<"${out}")" = "${cutoff}"
assert "the authored search uses the cutoff" \
    query_ran "author:haacked org:PostHog is:pr is:merged merged:>=${cutoff}"
assert "the involves search uses the cutoff" \
    query_ran "org:PostHog is:pr is:merged merged:>=${cutoff} involves:haacked -author:haacked"
assert "the reviewed-by search uses the cutoff" \
    query_ran "org:PostHog is:pr is:merged merged:>=${cutoff} reviewed-by:haacked -author:haacked"
assert "the open search runs" query_ran "author:haacked org:PostHog is:pr is:open"

assert "merged_authored holds the authored search" \
    test "$(urls_of merged_authored)" = "$(expect_urls "$(pr_url "${pp}" 100)" "$(pr_url "${pp}" 126045)")"
assert "items keep the search script's shape" test "$(jq_out '.merged_authored[] | select(.number == 100)')" = \
    '{"number":100,"title":"PR 100","url":"https://github.com/PostHog/posthog/pull/100","repo":"PostHog/posthog","author":"haacked","draft":false,"updated_at":"2026-11-03T10:00:00Z","merged_at":"2026-11-03T11:00:00Z"}'

assert "a bot-authored PR merged by haacked is agent_authored" \
    test "$(urls_of agent_authored)" = "$(expect_urls "$(pr_url "${pp}" 200)")"
assert "shepherded keeps approved and trunk-merged PRs once each" \
    test "$(urls_of shepherded)" = "$(expect_urls "$(pr_url "${pp}" 201)" "$(pr_url "${pjs}" 204)")"
assert "a PR haacked only commented on is dropped" \
    test "$(jq_out '[.. | objects | select(.url? == "https://github.com/PostHog/posthog/pull/203")] | length')" = 0
assert "a PR haacked requested changes on is dropped" \
    test "$(jq_out '[.. | objects | select(.url? == "https://github.com/PostHog/posthog/pull/206")] | length')" = 0
assert "a PR haacked never reviewed or merged is dropped" \
    test "$(jq_out '[.. | objects | select(.url? == "https://github.com/PostHog/posthog/pull/205")] | length')" = 0
assert "a teammate's PR is dropped" \
    test "$(jq_out '[.. | objects | select(.url? == "https://github.com/PostHog/posthog/pull/202")] | length')" = 0
assert "the roster runs when a human-authored PR is kept" roster_ran

assert "a non-draft open PR carries its review requests" \
    test "$(jq_out '.open[] | select(.number == 300) | .review_requests')" = '["alice","bob"]'
assert "a draft open PR has no review requests" \
    test "$(jq_out '.open[] | select(.number == 301) | .review_requests')" = '[]'
assert "an open PR not updated since the last standup is left out" \
    test "$(jq_out '[.open[].number]')" = '[300,301]'

assert "carry_over holds only the Working on PR URLs" test "$(urls_of carry_over)" = "$(expect_urls \
    "$(pr_url "${pp}" 126045)" "$(pr_url "${pp}" 1)" "$(pr_url "${pjs}" 77)" "$(pr_url "${pp}" 2)")"
assert "a carry-over PR carries its state and merge time" \
    test "$(jq_out '.carry_over[] | select(.url == "https://github.com/PostHog/posthog/pull/2")')" = \
    '{"url":"https://github.com/PostHog/posthog/pull/2","state":"MERGED","merged_at":"2026-11-01T09:00:00Z"}'
assert "an open carry-over PR has a null merge time" \
    test "$(jq_out '.carry_over[] | select(.url == "https://github.com/PostHog/posthog/pull/1") | [.state, .merged_at]')" = \
    '["OPEN",null]'

# A carry-over PR was open when the previous notes were written, so it belongs
# in must_list once merged, even when it merged before the cutoff.
assert "must_list holds merged, agent, shepherded, and every merged carry-over PR" \
    test "$(jq_out '.must_list | sort')" = "$(expect_urls \
        "$(pr_url "${pp}" 100)" "$(pr_url "${pp}" 126045)" "$(pr_url "${pp}" 200)" \
        "$(pr_url "${pp}" 201)" "$(pr_url "${pjs}" 204)" "$(pr_url "${pp}" 2)" "$(pr_url "${pjs}" 77)")"
assert "must_list has no duplicate URLs" test "$(jq_out '.must_list | length == (unique | length)')" = true

assert "a gather writes gather.json" test -f "${state_dir}/gather.json"
assert "gather.json records the standup-find.sh row that set the cutoff" \
    test "$(jq -r .basis "${state_dir}/gather.json")" = "$("${SCRIPT_DIR}/../standup-find.sh")"
assert "gather.json holds the printed object" \
    test "$(jq -cS 'del(.basis)' "${state_dir}/gather.json")" = "$(jq -cS . <<<"${out}")"

# Without a previous standup, the last standup date is the cutoff.

reset_case
search_fixture authored "$(raw_item 100 "${pp}" haacked false "2026-11-03T11:00:00Z")"
search_fixture involves \
    "$(raw_item 200 "${pp}" "posthog[bot]" false "2026-11-03T11:00:00Z")" \
    "$(raw_item 203 "${pp}" commenter false "2026-11-03T11:00:00Z")"
verified_fixture "$(pr_url "${pp}" 200)" haacked ""
verified_fixture "$(pr_url "${pp}" 203)" someone COMMENTED
run_gather "2026-11-02"
assert "a first gather succeeds" test "${rc}" -eq 0
assert "a first gather uses the last standup date as the cutoff" test "$(jq -r .cutoff <<<"${out}")" = "2026-11-02"
assert "a first gather searches from the last standup date" \
    query_ran "author:haacked org:PostHog is:pr is:merged merged:>=2026-11-02"
assert "a first gather has no carry-over" test "$(jq_out .carry_over)" = '[]'
assert "the roster does not run when no human-authored PR is kept" bash -c '! grep -qxF "orgs/PostHog/teams/team-feature-flags/members" "$1"' _ "${STUB_LOG}"
assert "a first gather's must_list holds the authored and agent PRs" \
    test "$(jq_out '.must_list | sort')" = "$(expect_urls "$(pr_url "${pp}" 100)" "$(pr_url "${pp}" 200)")"

reset_case
search_fixture authored "$(raw_item 100 "${pp}" haacked false "2026-11-03T11:00:00Z")"
run_gather "2026-11-02"
assert "a gather with nothing to verify succeeds" test "${rc}" -eq 0
assert "a gather with nothing to verify does not run the roster" bash -c '! grep -qxF "orgs/PostHog/teams/team-feature-flags/members" "$1"' _ "${STUB_LOG}"
assert "a gather with nothing to verify leaves the verified lists empty" \
    test "$(jq_out '[.agent_authored, .shepherded]')" = '[[],[]]'

# Any failed lookup fails the gather and writes no gather.json.

# assert_gather_refused <description> <env assignment>...
assert_gather_refused() {
    local description="$1"
    shift
    setup_full
    run_gather "2026-11-02" "$@"
    assert "${description} fails the gather" test "${rc}" -ne 0
    assert "${description} writes no gather.json" test ! -e "${state_dir}/gather.json"
}

assert_gather_refused "a failed verification lookup" STUB_FAIL_PR="$(pr_url "${pjs}" 204)"
assert_gather_refused "a failed carry-over lookup" STUB_FAIL_PR="$(pr_url "${pp}" 1)"
assert_gather_refused "a failed review-request lookup" STUB_FAIL_PR="$(pr_url "${pp}" 300)"
assert_gather_refused "a failed roster lookup" STUB_FAIL_ROSTER=1
assert_gather_refused "a failed authored search" STUB_FAIL_SEARCH=authored
assert_gather_refused "a failed involves search" STUB_FAIL_SEARCH=involves
assert_gather_refused "a failed reviewed-by search" STUB_FAIL_SEARCH=reviewed
assert_gather_refused "a failed open search" STUB_FAIL_SEARCH=open
assert_gather_refused "a truncated search" STUB_INCOMPLETE_SEARCH=involves

setup_full
mkdir -p "${state_dir}"
echo '{"sentinel":true}' > "${state_dir}/gather.json"
run_gather "2026-11-02" STUB_FAIL_ROSTER=1
assert "a failed gather removes an earlier gather.json" test ! -e "${state_dir}/gather.json"

# End to end: dates, gather, then save.

# notes_listing <url>... -> notes that list every URL.
notes_listing() {
    printf 'Yesterday:\n'
    printf -- '- Did a thing (%s - merged)\n' "$@"
}

setup_full
IFS=$'\t' read -r _ _ today_path <<<"$("${DATES}")"
run_gather "2026-11-02"
mapfile -t must_urls < <(jq -r '.must_list[]' <<<"${out}")
save_rc=0
notes_listing "${must_urls[@]}" | "${SAVE}" "${today_path}" > /dev/null 2>&1 || save_rc=$?
assert "a save after a passing gather succeeds" test "${save_rc}" -eq 0
assert "a save after a passing gather writes the notes" test -f "${today_path}"
save_rc=0
notes_listing "${must_urls[@]}" | "${SAVE}" "${today_path}" > /dev/null 2>&1 || save_rc=$?
assert "a second save without a new gather is refused" test "${save_rc}" -eq 1

setup_full
IFS=$'\t' read -r _ _ today_path <<<"$("${DATES}")"
run_gather "2026-11-02"
mapfile -t must_urls < <(jq -r '.must_list[]' <<<"${out}")
save_rc=0
notes_listing "${must_urls[@]:1}" | "${SAVE}" "${today_path}" > /dev/null 2>&1 || save_rc=$?
assert "a save after a passing gather that omits a must_list PR is refused" test "${save_rc}" -eq 1

setup_full
IFS=$'\t' read -r _ _ today_path <<<"$("${DATES}")"
run_gather "2026-11-02" STUB_FAIL_PR="$(pr_url "${pjs}" 204)"
save_rc=0
notes_listing "${must_urls[@]}" | "${SAVE}" "${today_path}" > /dev/null 2>&1 || save_rc=$?
assert "a save after a failed gather is refused" test "${save_rc}" -eq 1
assert "a save after a failed gather writes no notes" test ! -e "${today_path}"

reset_case
rc=0
"${GATHER}" > /dev/null 2>&1 || rc=$?
assert "a gather with no date is a usage error" test "${rc}" -eq 64
assert "a gather usage error writes no gather.json" test ! -e "${state_dir}/gather.json"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
