#!/bin/bash
# Tests for bin/triage-flags-pr-candidates and the jq filters it loads:
# triage-pr-classify.jq (splits search results into internal and external PRs)
# and triage-pr-candidates.jq (joins them with the per-PR fetch results). The
# script itself runs against a stub gh.
#
# Usage: test-triage-pr-candidates.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

classify() {
    local search="$1"
    local limit="${2:-1000}"
    echo "$search" | jq --argjson limit "$limit" -f "$SCRIPT_DIR/triage-pr-classify.jq"
}

candidates() {
    local search="$1"
    local details="$2"
    local limit="${3:-1000}"
    classify "$search" "$limit" | jq --argjson details "$details" -f "$SCRIPT_DIR/triage-pr-candidates.jq"
}

make_pr() {
    # number login association author_type is_draft [comma-separated labels]
    jq -n --argjson n "$1" --arg l "$2" --arg a "$3" --arg t "$4" --argjson d "$5" --arg labels "${6:-}" '{
        number: $n,
        title: ("PR " + ($n | tostring)),
        author: {login: $l, type: $t, is_bot: false},
        authorAssociation: $a,
        isDraft: $d,
        labels: ($labels | split(",") | map(select(length > 0) | {name: ., color: "aaaaaa"}))
    }'
}

numbers() {
    echo "$1" | jq -c "[$2[].number]"
}

# ── Test data ─────────────────────────────────────────────────────────────

ext_ready=$(make_pr 101 contributor CONTRIBUTOR User false "bug,community")
ext_draft=$(make_pr 102 drafter CONTRIBUTOR User true)
int_member=$(make_pr 103 member MEMBER User false)
int_owner_draft=$(make_pr 104 owner OWNER User true)
int_collab_no_flags=$(make_pr 105 collaborator COLLABORATOR User false)
app_bot=$(make_pr 106 "posthog[bot]" CONTRIBUTOR Bot false)
user_bot=$(make_pr 107 posthog-bot MEMBER User false)
ext_unfetched=$(make_pr 108 stranger NONE User false)
int_unfetched=$(make_pr 109 member2 MEMBER User false)
int_many_files=$(make_pr 110 member3 MEMBER User false)
ext_first_timer=$(make_pr 111 newcomer FIRST_TIME_CONTRIBUTOR User false)
typed_bot=$(make_pr 112 some-app MEMBER Bot false)
dependabot=$(make_pr 113 dependabot CONTRIBUTOR User false)

search=$(jq -s '.' <<EOF
$int_many_files
$ext_ready
$ext_draft
$int_member
$int_owner_draft
$int_collab_no_flags
$app_bot
$user_bot
$ext_unfetched
$int_unfetched
$ext_first_timer
$typed_bot
$dependabot
EOF
)

many_files=$(jq -nc '[range(0; 120) | "posthog/api/file_\(.).py"] + ["posthog/models/cohort/util.py"]')

details=$(jq -n --argjson many "$many_files" '[
    {number: 101, files: ["posthog/models/feature_flag/flag_matching.py", "README.md"], reviewDecision: "REVIEW_REQUIRED"},
    {number: 111, files: [], reviewDecision: "APPROVED"},
    {number: 103, files: ["posthog/api/insight.py", "rust/feature-flags/src/lib.rs", "frontend/src/scenes/Cohorts/Cohort.tsx"]},
    {number: 104, files: ["frontend/src/scenes/early-access-features/EarlyAccess.tsx"]},
    {number: 105, files: ["posthog/api/insight.py", "frontend/src/scenes/dashboard/Dashboard.tsx"]},
    {number: 110, files: $many}
]')

# ── Test: classify splits PRs by author association ───────────────────────

classified=$(classify "$search")

assert "classify: members, owners, and collaborators are internal" \
    test "$(echo "$classified" | jq -c '[.prs[] | select(.internal) | .number]')" = "[103,104,105,109,110]"
assert "classify: other associations are external, and external drafts are dropped" \
    test "$(echo "$classified" | jq -c '[.prs[] | select(.internal | not) | .number]')" = "[101,108,111]"
assert "classify: a Bot-typed account is dropped even with a CONTRIBUTOR association" \
    test "$(echo "$classified" | jq '[.prs[] | select(.number == 106)] | length')" -eq 0
assert "classify: a Bot-typed account without [bot] in its login is dropped" \
    test "$(echo "$classified" | jq '[.prs[] | select(.number == 112)] | length')" -eq 0
assert "classify: a user account matching the bot login pattern is dropped" \
    test "$(echo "$classified" | jq '[.prs[] | select(.number == 107 or .number == 113)] | length')" -eq 0
assert "classify: fetched counts every search result, including bots and drafts" \
    test "$(echo "$classified" | jq '.fetched')" -eq 13

# ── Test: external PRs ────────────────────────────────────────────────────

result=$(candidates "$search" "$details")

assert "external: non-draft, non-bot, non-member PRs sorted by number" \
    test "$(numbers "$result" .external)" = "[101,108,111]"
assert "external: carries files from the per-PR fetch" \
    test "$(echo "$result" | jq -c '.external[] | select(.number == 101) | .files')" \
        = '["posthog/models/feature_flag/flag_matching.py","README.md"]'
assert "external: carries reviewDecision from the per-PR fetch" \
    test "$(echo "$result" | jq -r '.external[] | select(.number == 101) | .reviewDecision')" = "REVIEW_REQUIRED"
assert "external: carries label names" \
    test "$(echo "$result" | jq -c '.external[] | select(.number == 101) | .labels')" = '["bug","community"]'
assert "external: carries title and author login" \
    test "$(echo "$result" | jq -c '.external[] | select(.number == 101) | [.title, .author]')" = '["PR 101","contributor"]'
assert "external: a fetched PR with no files keeps an empty list, not null" \
    test "$(echo "$result" | jq -c '.external[] | select(.number == 111) | .files')" = "[]"
assert "external: a PR whose fetch failed is kept with null files" \
    test "$(echo "$result" | jq -c '.external[] | select(.number == 108) | .files')" = "null"
assert "external: a PR whose fetch failed is kept with null reviewDecision" \
    test "$(echo "$result" | jq -c '.external[] | select(.number == 108) | .reviewDecision')" = "null"

# ── Test: internal PRs ────────────────────────────────────────────────────

assert "internal: only PRs touching a flags path, sorted by number" \
    test "$(numbers "$result" .internal)" = "[103,104,110]"
assert "internal: lists only the matching paths, matched case-insensitively" \
    test "$(echo "$result" | jq -c '.internal[] | select(.number == 103) | .paths')" \
        = '["rust/feature-flags/src/lib.rs","frontend/src/scenes/Cohorts/Cohort.tsx"]'
assert "internal: a match beyond the first 100 files is found" \
    test "$(echo "$result" | jq -c '.internal[] | select(.number == 110) | .paths')" = '["posthog/models/cohort/util.py"]'
assert "internal: a draft is kept with isDraft true" \
    test "$(echo "$result" | jq '.internal[] | select(.number == 104) | .isDraft')" = "true"
assert "internal: a ready PR has isDraft false" \
    test "$(echo "$result" | jq '.internal[] | select(.number == 103) | .isDraft')" = "false"
assert "internal: carries title and author login" \
    test "$(echo "$result" | jq -c '.internal[] | select(.number == 103) | [.title, .author]')" = '["PR 103","member"]'

# ── Test: failed per-PR fetches ───────────────────────────────────────────

assert "unfetched: lists every kept PR with no fetch result, internal and external" \
    test "$(echo "$result" | jq -c '.unfetched')" = "[108,109]"
assert "unfetched: an internal PR whose fetch failed is not an internal candidate" \
    test "$(echo "$result" | jq '[.internal[] | select(.number == 109)] | length')" -eq 0

# ── Test: search cap ──────────────────────────────────────────────────────

assert "capped is false when fetched is under the limit" \
    test "$(echo "$result" | jq '.capped')" = "false"
assert "fetched passes through to the output" \
    test "$(echo "$result" | jq '.fetched')" -eq 13

result=$(candidates "$search" "$details" 13)
assert "capped is true when fetched equals the limit" \
    test "$(echo "$result" | jq '.capped')" = "true"

# ── Test: empty search ────────────────────────────────────────────────────

result=$(candidates "[]" "[]")
assert "empty search produces empty lists and no cap" \
    test "$(echo "$result" | jq -c '[.fetched, .capped, .external, .internal, .unfetched]')" = "[0,false,[],[],[]]"

# ── Test: the helper script against a stub gh ─────────────────────────────

HELPER="$SCRIPT_DIR/../triage-flags-pr-candidates"
GH_STUB=$(mktemp -d)
trap 'rm -rf "$GH_STUB"' EXIT
mkdir -p "$GH_STUB/bin" "$GH_STUB/fixtures"

# The stub answers the three gh calls the helper makes from fixture files. A
# PR with no fixture file makes its per-PR call fail.
cat >"$GH_STUB/bin/gh" <<'STUB'
#!/bin/bash
fixtures="$GH_FIXTURES"
if [[ "$1 $2" == "search prs" ]]; then
    printf '%s\0' "$@" >"$fixtures/search-args"
    cat "$fixtures/search.json"
elif [[ "$1 $2" == "pr view" ]]; then
    cat "$fixtures/view-$3.json" 2>/dev/null
elif [[ "$1" == "api" ]]; then
    number=${2#repos/PostHog/posthog/pulls/}
    cat "$fixtures/files-${number%/files}.txt" 2>/dev/null
else
    exit 64
fi
STUB
chmod +x "$GH_STUB/bin/gh"

write_gh_fixtures() { # search-json details-json
    rm -f "$GH_STUB/fixtures"/*
    printf '%s\n' "$1" >"$GH_STUB/fixtures/search.json"
    local number
    for number in $(echo "$2" | jq -r '.[] | select(has("reviewDecision")) | .number'); do
        echo "$2" | jq -c ".[] | select(.number == $number)" >"$GH_STUB/fixtures/view-$number.json"
    done
    for number in $(echo "$2" | jq -r '.[] | select(has("reviewDecision") | not) | .number'); do
        echo "$2" | jq -r ".[] | select(.number == $number) | .files[]" >"$GH_STUB/fixtures/files-$number.txt"
    done
}

run_helper() {
    PATH="$GH_STUB/bin:$PATH" GH_FIXTURES="$GH_STUB/fixtures" "$HELPER" --days 7 2>/dev/null
}

search_args_include() { # arg
    local arg
    while IFS= read -r -d '' arg; do
        [[ "$arg" == "$1" ]] && return 0
    done <"$GH_STUB/fixtures/search-args"
    return 1
}

write_gh_fixtures "$search" "$details"
helper_status=0
helper_out=$(run_helper) || helper_status=$?

assert "helper exits 0" test "$helper_status" -eq 0
assert "helper output matches the jq filters run on the same data" \
    test "$(echo "$helper_out" | jq -Sc .)" = "$(candidates "$search" "$details" | jq -Sc .)"
assert "helper passes each label exclusion as its own search argument" search_args_include "-label:team/feature-flags"
assert "helper excludes posthog[bot] as its own search argument" search_args_include "-author:app/posthog"
assert "helper sorts the search by creation date" search_args_include "created"
assert "helper sorts the search newest first" search_args_include "desc"

write_gh_fixtures "[]" "[]"
assert "helper prints empty lists for an empty search" \
    test "$(run_helper | jq -c '[.fetched, .capped, .external, .internal, .unfetched]')" = "[0,false,[],[],[]]"

# ── Results ───────────────────────────────────────────────────────────────

print_results
