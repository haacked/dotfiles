#!/bin/bash
# Tests for bin/triage-issue-queue, run against a stub gh that serves raw
# GitHub API responses from fixtures. The assertions read only the helper's
# stdout JSON and the log of gh calls it made, so they hold however the helper
# splits its work between jq filters.
#
# Usage: test-triage-issue-queue.sh

# shellcheck disable=SC2016 # jq filters contain a literal $.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/test-triage-stub.sh
source "$SCRIPT_DIR/test-triage-stub.sh"

HELPER="$SCRIPT_DIR/../triage-issue-queue"

# A missing search or load fixture fails the call.
write_gh_stub <<'DISPATCH'
[[ "$1 ${2-}" == "issue list" ]] && serve "$fixtures/search.json"
serve_load "repo:PostHog/posthog is:issue is:open assignee:"
DISPATCH

# Applies filter $1 to flags_areas from bin/lib/flags-domain.jq.
from_flags_areas() { # filter
    jq -nSc -L "$SCRIPT_DIR" "include \"flags-domain\"; flags_areas | $1"
}

ROSTER_UNAVAILABLE='{"reason":"team roster unavailable","reviewer":null}'

# ── Fixture builders ──────────────────────────────────────────────────────

user() { # login
    jq -nc --arg login "$1" '{id: "U_1", is_bot: false, login: $login, name: ""}'
}

BOT='{"id":"BOT_kgDOBhzYcQ","is_bot":true,"login":"app/github-actions","name":""}'
OUTSIDER=$(user outside-dev)
FLAGS_LABEL="team/feature-flags"

make_issue() { # number author-json labels-csv [json merged over the defaults]
    local overrides="${4:-}"
    [[ -n "$overrides" ]] || overrides='{}'
    jq -nc --argjson n "$1" --argjson author "$2" --arg labels "$3" --arg body "$INJECTION" \
        --arg created "$(created_ago 1)" --argjson overrides "$overrides" '{
        number: $n,
        title: "Flags issue \($n)",
        author: $author,
        body: $body,
        createdAt: $created,
        labels: ($labels | split(",") | map(select(length > 0) | {id: "LA_1", name: ., description: "", color: "aaaaaa"}))
    } + $overrides'
}

# ── Reading the helper's output ───────────────────────────────────────────

listed() { # number
    out --argjson n "$1" 'any(.issues[]; .number == $n)'
}

# Applies filter $2 to issue $1's entry in issues.
issue() { # number filter
    out --argjson n "$1" "[.issues[] | select(.number == \$n)] | first | $2"
}

# Applies filter $2 to the entry for code area $1.
area() { # area filter
    out --arg area "$1" ".areas[\$area] | $2"
}

# Prints the path= value of every commit-history call, sorted.
history_paths() {
    calls '[.[] | select(any(.[]; . == "repos/PostHog/posthog/commits")) | .[] | select(startswith("path=")) | .[5:]] | sort'
}

# Succeeds when the issue list call passes flag $1 with value $2.
search_has() { # flag value
    test "$(calls --arg flag "$1" --arg value "$2" '[.[] | select(.[0:2] == ["issue", "list"])
        | . as $argv | range(0; length - 1) | select($argv[.] == $flag and $argv[. + 1] == $value)] | length > 0')" = "true"
}

search_text_has() { # text
    test "$(calls --arg text "$1" '[.[] | select(.[0:2] == ["issue", "list"]) | .[] | select(contains($text))] | length > 0')" = "true"
}

utc_date_days_ago() { # days
    jq -rn --argjson days "$1" '(now - $days * 86400) | todate[0:10]'
}

search_date_is_days_ago() { # days
    test "$(calls -r '[.[] | select(.[0:2] == ["issue", "list"]) | .[]
        | capture("created:>=(?<d>[0-9]{4}-[0-9]{2}-[0-9]{2})").d] | first // ""')" = "$(utc_date_days_ago "$1")"
}

# Succeeds when the helper exits 2 with an error and no output for arguments
# $@, before making any gh call.
rejects() { # helper-arg...
    reset_fixtures
    run_helper "$@"
    [[ "$helper_status" -eq 2 && -z "$helper_out" && -s "$GH_STUB/stderr" ]] && test "$(calls 'length')" = "0"
}

# ── Main scenario fixtures ────────────────────────────────────────────────
#
# Roster: alice (load unknown), bob (9), carol (6), dave (4). rubychilds is on
# the GitHub team with a load of 0 and the most commits in feature flags app,
# so proposing her would change that area's proposal and every proposal made
# on load alone.
#
# 101-104  one flags label each, filed by an outsider
# 105      no labels
# 106      non-flags labels only
# 107      a label that only starts with a flags label name
# 108      filed by alice, a team member
# 109      filed by rubychilds
# 120      filed by a bot
# 121      a flags label after a non-flags label, filed by a bot
# 130      a title with markdown, a pipe, CR, and LF
# 140      ten days old, with two labels
#
# feature flags app        bob 7 beats alice 2; non-roster, bot, unlinked, and
#                          rubychilds commits each outnumber bob's
# cohort processing        alice has one commit in each of the area's paths
# flag evaluation service  bob 2 and carol 2 tie; carol has the lower load
# cohorts app              alice 2 and bob 2 tie; alice's load is unknown
# early access             commits from outside the roster only

reset_fixtures
write_members dave rubychilds bob carol alice
write_load bob 9
write_load carol 6
write_load dave 4
write_load rubychilds 0

search=$(json_list \
    "$(make_issue 140 "$OUTSIDER" "$FLAGS_LABEL,stale" "$(jq -nc --arg c "$(created_ago 10)" '{createdAt: $c}')")" \
    "$(make_issue 130 "$OUTSIDER" "$FLAGS_LABEL" "$(jq -nc '{title: "Fix [broken flag](https://example.com/a) |  now\r\nsee ![screen shot](https://example.com/x.png)"}')")" \
    "$(make_issue 109 "$(user rubychilds)" "feature/cohorts")" \
    "$(make_issue 101 "$OUTSIDER" "team/feature-flags")" \
    "$(make_issue 121 "$BOT" "bug,feature/cohorts")" \
    "$(make_issue 105 "$OUTSIDER" "")" \
    "$(make_issue 102 "$OUTSIDER" "feature/feature-flags")" \
    "$(make_issue 108 "$(user alice)" "$FLAGS_LABEL,bug")" \
    "$(make_issue 106 "$OUTSIDER" "bug,feature/insights")" \
    "$(make_issue 103 "$OUTSIDER" "feature/cohorts")" \
    "$(make_issue 120 "$BOT" "$FLAGS_LABEL")" \
    "$(make_issue 107 "$OUTSIDER" "team/feature-flags-platform")" \
    "$(make_issue 104 "$OUTSIDER" "feature/early-access-management")" \
)
write_fixture search.json "$search"

write_history products/feature_flags \
    alice:User:2 zed:User:8 "posthog[bot]:Bot:8" :User:8 rubychilds:User:8 bob:User:7
write_history rust/cohort-core alice:User
write_history rust/cohort-stream-processor alice:User
write_history rust/feature-flags bob:User:2 alice:User carol:User:2
write_history products/cohorts alice:User:2 bob:User:2
write_history products/early_access_features zed:User:3 "posthog[bot]:Bot:2" :User

run_helper

# ── Test: output shape ────────────────────────────────────────────────────

assert "helper exits 0" test "$helper_status" -eq 0
assert "helper prints one JSON object" prints_one_object
assert "output has exactly the documented top-level fields" \
    test "$(out 'keys')" = "$(jq -nc '["fetched", "capped", "roster", "issues", "teamFiled", "areas", "fallback", "historyUnavailable"] | sort')"
assert "every issues entry has exactly the documented fields" \
    test "$(out '[.issues[] | keys] | unique')" = '[["ageDays","author","labels","number","title"]]'
assert "areas holds each group in flags_areas with its paths" \
    test "$(out '.areas | map_values(.paths)')" = "$(from_flags_areas 'map({(.name): .paths}) | add')"
assert "every area has exactly paths and proposal" \
    test "$(out '[.areas[] | keys] | unique')" = '[["paths","proposal"]]'
assert "every proposal and the fallback have exactly reviewer and reason" \
    test "$(out '[.areas[].proposal, .fallback | keys] | unique')" = '[["reason","reviewer"]]'

# ── Test: issue search ────────────────────────────────────────────────────

assert "fetched counts every search result, including dropped issues" \
    test "$(out '.fetched')" = "$(echo "$search" | jq 'length')"
assert "capped is false when fetched is under the limit" test "$(out '.capped')" = "false"
assert "search: queries PostHog/posthog" search_has --repo PostHog/posthog
assert "search: asks for open issues" search_has --state open
assert "search: asks for up to 1000 issues" search_has --limit 1000
assert "search: asks for unassigned issues" search_text_has "no:assignee"
assert "search: defaults to issues created since the UTC date 14 days ago" search_date_is_days_ago 14
assert "search: never asks for issue bodies" \
    test "$(calls '[.[] | select(.[0:2] == ["issue", "list"]) | . as $argv
        | range(0; length - 1) | select($argv[.] == "--json") | $argv[. + 1] | split(",") | index("body")]
        | length > 0 and all(. == null)')" = "true"

# ── Test: label filter ────────────────────────────────────────────────────

for entry in 101:team/feature-flags 102:feature/feature-flags 103:feature/cohorts 104:feature/early-access-management; do
    assert "labels: the ${entry#*:} label alone keeps an issue" test "$(listed "${entry%%:*}")" = "true"
done
assert "labels: a flags label after a non-flags label keeps an issue" test "$(listed 121)" = "true"
assert "labels: an unlabeled issue is dropped" test "$(listed 105)" = "false"
assert "labels: an issue with only non-flags labels is dropped" test "$(listed 106)" = "false"
assert "labels: a label that only starts with a flags label name does not keep an issue" \
    test "$(listed 107)" = "false"
assert "issues lists exactly the kept issues" \
    test "$(out '[.issues[].number] | sort')" = "[101,102,103,104,120,121,130,140]"
assert "issues are sorted by number ascending" test "$(out '[.issues[].number] | . == sort')" = "true"

# ── Test: authors ─────────────────────────────────────────────────────────

assert "authors: an issue filed by a non-team human is kept" test "$(issue 101 '.author')" = '"outside-dev"'
assert "authors: an issue filed by a bot is kept with the bot's login" \
    test "$(issue 120 '.author')" = '"app/github-actions"'
assert "team-filed: an issue filed by a team member is not listed" test "$(listed 108)" = "false"
assert "team-filed: an issue filed by rubychilds is not listed" test "$(listed 109)" = "false"
assert "team-filed: teamFiled counts both skipped issues" test "$(out '.teamFiled')" = "2"

# ── Test: per-issue fields ────────────────────────────────────────────────

assert "title passes through" test "$(issue 101 '.title')" = '"Flags issue 101"'
assert "title: markdown links and images, pipes, CR, and LF become plain text" \
    test "$(issue 130 '.title')" = '"Fix broken flag now see screen shot"'
assert "labels lists label names" test "$(issue 140 '.labels | sort')" = '["stale","team/feature-flags"]'
assert "ageDays counts whole days since creation" test "$(issue 140 '.ageDays')" = "10"
assert "ageDays is 1 for an issue created a day and a half ago" test "$(issue 101 '.ageDays')" = "1"

# ── Test: roster and open-issue load ──────────────────────────────────────

assert "roster lists team members without rubychilds" \
    test "$(out '.roster | sort')" = '["alice","bob","carol","dave"]'
assert "load is looked up once for each roster member" \
    test "$(load_logins)" = '["alice","bob","carol","dave"]'

# ── Test: proposals ───────────────────────────────────────────────────────

assert "proposal: only roster members' commits count, though outsider, bot, unlinked, and rubychilds commits each outnumber the winner's" \
    test "$(area "feature flags app" '.proposal')" = '{"reason":"7 commits in feature flags app in 180 days","reviewer":"bob"}'
assert "proposal: commits add up across an area's paths" \
    test "$(area "cohort processing" '.proposal')" = '{"reason":"2 commits in cohort processing in 180 days","reviewer":"alice"}'
assert "proposal: a commit tie goes to the lower open-issue load" \
    test "$(area "flag evaluation service" '.proposal')" = '{"reason":"2 commits in flag evaluation service in 180 days","reviewer":"carol"}'
assert "proposal: a member with an unknown load ranks after one with any known load" \
    test "$(area "cohorts app" '.proposal')" = '{"reason":"2 commits in cohorts app in 180 days","reviewer":"bob"}'
assert "proposal: with commits from outside the roster only, the lowest open-issue load is proposed" \
    test "$(area "early access" '.proposal')" = '{"reason":"no team commits in early access; fewest open assigned issues (4)","reviewer":"dave"}'
assert "fallback: the roster member with the lowest open-issue load is proposed" \
    test "$(out '.fallback')" = '{"reason":"no code area fits; fewest open assigned issues (4)","reviewer":"dave"}'

# ── Test: commit-history calls ────────────────────────────────────────────

assert "commit history: each path in flags_areas is queried exactly once" \
    test "$(history_paths)" = "$(from_flags_areas '[.[].paths[]] | sort')"
assert "commit history: every call asks for commits since the UTC midnight 180 days ago" \
    test "$(calls '[.[] | select(any(.[]; . == "repos/PostHog/posthog/commits")) | [.[] | select(startswith("since="))]] | unique')" \
    = "[[\"since=$(utc_date_days_ago 180)T00:00:00Z\"]]"
assert "commit history: historyUnavailable is empty when every call succeeds" test "$(out '.historyUnavailable')" = "[]"

# ── Test: read-only and trust fence ───────────────────────────────────────

assert "helper makes no gh call that could change state" test "$(write_calls)" = "0"
assert "trust fence: output has no body or message key anywhere" lacks_body_or_message_key
assert "trust fence: output does not contain the injected text" lacks_injection "$helper_out"
assert "trust fence: progress output does not contain the injected text" stderr_lacks_injection

# ── Test: --days ──────────────────────────────────────────────────────────

reset_fixtures
write_members alice
write_load alice 0
write_fixture search.json "$(json_list "$(make_issue 801 "$OUTSIDER" "$FLAGS_LABEL")")"

run_helper --days 30

assert "--days: helper exits 0" test "$helper_status" -eq 0
assert "--days: the search asks for issues created since the UTC date N days ago" search_date_is_days_ago 30

assert "--days: 0 is rejected" rejects --days 0
assert "--days: a value that is not a number is rejected" rejects --days abc
assert "--days: a missing value is rejected" rejects --days

# ── Test: roster call fails ───────────────────────────────────────────────

reset_fixtures
write_fixture search.json "$(json_list \
    "$(make_issue 601 "$(user alice)" "$FLAGS_LABEL")" \
    "$(make_issue 602 "$(user rubychilds)" "$FLAGS_LABEL")" \
    "$(make_issue 603 "$OUTSIDER" "$FLAGS_LABEL")")"
write_history products/feature_flags alice:User:3

run_helper

assert "roster failure: helper still exits 0" test "$helper_status" -eq 0
assert "roster failure: roster is null" test "$(out '.roster')" = "null"
assert "roster failure: no issue is skipped as team-filed" \
    test "$(out '[.issues[].number] | sort')" = "[601,602,603]"
assert "roster failure: teamFiled is 0" test "$(out '.teamFiled')" = "0"
assert "roster failure: every area proposes no one because the roster is unavailable" \
    test "$(out '.areas | map_values(.proposal)')" = "$(from_flags_areas "map({(.name): $ROSTER_UNAVAILABLE}) | add")"
assert "roster failure: the fallback proposes no one" test "$(out '.fallback')" = "$ROSTER_UNAVAILABLE"

# ── Test: ties on commits and load ────────────────────────────────────────

reset_fixtures
write_members mia lee
write_load mia 5
write_load lee 5
write_fixture search.json "$(json_list "$(make_issue 701 "$OUTSIDER" "$FLAGS_LABEL")")"
write_history posthog/api/cohort.py mia:User:3 lee:User:3

run_helper

assert "alphabetical: helper exits 0" test "$helper_status" -eq 0
assert "alphabetical: a tie on commits and load goes to the alphabetically first login" \
    test "$(area "cohorts app" '.proposal.reviewer')" = '"lee"'
assert "alphabetical: a fallback tie on load goes to the alphabetically first login" \
    test "$(out '.fallback.reviewer')" = '"lee"'

# ── Test: every load lookup fails ─────────────────────────────────────────

reset_fixtures
write_members bob alice
write_fixture search.json "$(json_list "$(make_issue 901 "$OUTSIDER" "$FLAGS_LABEL")")"

run_helper

assert "unknown load: helper exits 0" test "$helper_status" -eq 0
assert "unknown load: the fallback goes to the alphabetically first login and says the load is unknown" \
    test "$(out '.fallback')" = '{"reason":"no code area fits; fewest open assigned issues (unknown)","reviewer":"alice"}'
assert "unknown load: a no-commit area reason says the load is unknown" \
    test "$(area "feature flags app" '.proposal')" = '{"reason":"no team commits in feature flags app; fewest open assigned issues (unknown)","reviewer":"alice"}'

# ── Test: a commit-history call fails ─────────────────────────────────────

reset_fixtures
write_members alice bob
write_load alice 1
write_load bob 0
write_fixture search.json "$(json_list "$(make_issue 1001 "$OUTSIDER" "$FLAGS_LABEL")")"
fail_history rust/feature-flags
write_history rust/flags-consumer alice:User

run_helper

assert "history failure: helper exits 0" test "$helper_status" -eq 0
assert "history failure: historyUnavailable lists the path whose call failed" \
    test "$(out '.historyUnavailable')" = '["rust/feature-flags"]'
assert "history failure: the area's reason says some history failed to load" \
    test "$(area "flag evaluation service" '.proposal')" = '{"reason":"1 commit in flag evaluation service in 180 days; some commit history failed to load","reviewer":"alice"}'
assert "history failure: an area whose history loaded keeps its plain reason" \
    test "$(area "cohort processing" '.proposal')" = '{"reason":"no team commits in cohort processing; fewest open assigned issues (0)","reviewer":"bob"}'

# ── Test: empty search ────────────────────────────────────────────────────

reset_fixtures
write_members alice
write_load alice 0
write_fixture search.json "[]"

run_helper

assert "empty search: helper exits 0" test "$helper_status" -eq 0
assert "empty search: no issues, zero counts, and no cap" \
    test "$(out '[.fetched, .capped, .issues, .teamFiled]')" = "[0,false,[],0]"

# ── Test: search cap ──────────────────────────────────────────────────────

reset_fixtures
write_members alice
write_load alice 0
write_fixture search.json "$(jq -nc --arg created "$(created_ago 1)" '[range(0; 1000) | {
    number: (5000 + .), title: "Unrelated issue", author: {login: "outside-dev", is_bot: false},
    createdAt: $created, labels: []
}]')"

run_helper

assert "cap: capped is true when fetched reaches the 1000 limit" test "$(out '[.fetched, .capped]')" = "[1000,true]"

# ── Results ───────────────────────────────────────────────────────────────

print_results
