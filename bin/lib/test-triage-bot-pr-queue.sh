#!/bin/bash
# Tests for bin/triage-bot-pr-queue, run against a stub gh that serves raw
# GitHub API responses from fixtures. The assertions read only the helper's
# stdout JSON and the log of gh calls it made, so they hold however the helper
# splits its work between jq filters.
#
# Usage: test-triage-bot-pr-queue.sh

# shellcheck disable=SC2016 # jq filters contain a literal $.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/test-triage-stub.sh
source "$SCRIPT_DIR/test-triage-stub.sh"

HELPER="$SCRIPT_DIR/../triage-bot-pr-queue"

# A missing files or load fixture fails the call. A missing timeline or PR
# commits fixture serves an empty list. A timeline or commits .fail fixture
# fails the call.
write_gh_stub <<'DISPATCH'
files_re='^repos/PostHog/posthog/pulls/([0-9]+)/files$'
timeline_re='^repos/PostHog/posthog/issues/([0-9]+)/timeline$'
commits_re='^repos/PostHog/posthog/pulls/([0-9]+)/commits$'

[[ "$1 ${2-}" == "pr list" ]] && serve "$fixtures/search.json"
[[ "$endpoint" =~ $files_re ]] && serve "$fixtures/files-${BASH_REMATCH[1]}.json"
if [[ "$endpoint" =~ $timeline_re ]]; then
    [[ -f "$fixtures/timeline-${BASH_REMATCH[1]}.fail" ]] && exit 1
    serve "$fixtures/timeline-${BASH_REMATCH[1]}.json" '[]'
fi
if [[ "$endpoint" =~ $commits_re ]]; then
    [[ -f "$fixtures/commits-${BASH_REMATCH[1]}.fail" ]] && exit 1
    serve "$fixtures/commits-${BASH_REMATCH[1]}.json" '[]'
fi
serve_load "repo:PostHog/posthog is:pr is:open user-review-requested:"
DISPATCH

# ── Fixture builders ──────────────────────────────────────────────────────

APP='{"id":"BOT_kgDOBhzYcQ","is_bot":true,"login":"app/posthog","name":""}'
FLAGS_LABEL="team/feature-flags"

make_pr() { # number author-json labels-csv [json merged over the defaults]
    local overrides="${4:-}"
    [[ -n "$overrides" ]] || overrides='{}'
    jq -nc --argjson n "$1" --argjson author "$2" --arg labels "$3" --arg body "$INJECTION" \
        --arg created "$(created_ago 1)" --argjson overrides "$overrides" '{
        number: $n,
        title: "Fix flags thing \($n)",
        body: $body,
        author: $author,
        headRefName: "posthog-self-driving/fix-\($n)",
        createdAt: $created,
        labels: ($labels | split(",") | map(select(length > 0) | {id: "LA_1", name: ., description: "", color: "aaaaaa"})),
        assignees: [],
        reviewRequests: []
    } + $overrides'
}

write_files() { # number path...
    local number="$1"
    shift
    jq -nc '$ARGS.positional | map({filename: ., status: "modified", additions: 1, deletions: 0})' --args "$@" \
        >"$FIXTURES/files-$number.json"
}

review() { # login user-type state
    jq -nc --arg login "$1" --arg type "$2" --arg state "$3" --arg body "$INJECTION" '{
        event: "reviewed", id: 1, state: $state, body: $body,
        user: {login: $login, type: $type}, submitted_at: "2026-10-12T00:00:00Z"
    }'
}

ready_event() { # login actor-type
    jq -nc --arg login "$1" --arg type "$2" \
        '{event: "ready_for_review", actor: {login: $login, type: $type}, created_at: "2026-10-11T00:00:00Z"}'
}

# ── Reading the helper's output ───────────────────────────────────────────

# Prints the output lists that hold PR $1, as a JSON array such as ["prs"].
placement() { # number
    out --argjson n "$1" '[
        if any(.prs[]; .number == $n) then "prs" else empty end,
        if any(.commented[]; .number == $n) then "commented" else empty end,
        if any(.reviewed[]; . == $n) then "reviewed" else empty end,
        if any(.unfetched[]; . == $n) then "unfetched" else empty end
    ]'
}

# Applies filter $2 to PR $1's entry in prs or commented.
pr() { # number filter
    out --argjson n "$1" "[.prs[], .commented[] | select(.number == \$n)] | first | $2"
}

# Applies filter $3 to the entry for login $2 in PR $1's humans.
human() { # number login filter
    pr "$1" "[.humans[] | select(.login == \"$2\")] | first | $3"
}

files_calls() { # number
    calls --arg n "$1" '[.[] | select(any(.[]; test("^repos/PostHog/posthog/pulls/\($n)/files")))] | length'
}

SUMMARY_FIELDS='["number", "title", "bot", "ageDays", "stale", "labels", "botApproved",
    "humans", "flagsPaths", "fileCount"]'
PR_FIELDS=$(jq -nc "$SUMMARY_FIELDS + [\"proposal\"] | sort")
COMMENTED_FIELDS=$(jq -nc "$SUMMARY_FIELDS + [\"commenters\"] | sort")
TEAM_REVIEWER='"PostHog/team-feature-flags"'

# ── Main scenario fixtures ────────────────────────────────────────────────
#
# Roster: alice (load 2), bob (0), carol (1), dave (lookup fails). rubychilds
# is on the GitHub team and has the most commits in posthog/models/feature_flag,
# so proposing her would change 252's proposal.
#
# 201, 204, 207 bot author shapes, each in scope
# 208      human author with a flags label (dropped)
# 209, 219 bot PRs with a user or team review request (dropped)
# 210, 215-217 in scope by label alone
# 211      in scope by path alone
# 212, 213 out of scope
# 214      files fetch fails
# 218      timeline fetch fails
# 229      PR commits fetch fails
# 220-228  review classification
# 230      humans behind the PR
# 231      roster members found as marked-ready and as commit author
# 232      every roster member is behind the PR
# 240      stale and old
# 250      in scope by a flags- crate path alone
# 251      seven flags directories, with commits in three of the five queried
#          and in one past the cap
# 252      recent commits by roster members and by everyone else
# 253      recent commits tied between roster members
# 254      flags paths in a directory and in its subdirectory
# 260      a title with markdown, a pipe, a newline, and Slack pings

reset_fixtures
write_members alice bob carol dave rubychilds
write_load alice 2
write_load bob 0
write_load carol 1

search=$(json_list \
    "$(make_pr 201 '{"login":"some-github-app","is_bot":true}' "$FLAGS_LABEL")" \
    "$(make_pr 204 '{"login":"app/scheduled-actions-posthog","is_bot":false}' "$FLAGS_LABEL")" \
    "$(make_pr 207 '{"login":"github-actions","is_bot":false}' "$FLAGS_LABEL")" \
    "$(make_pr 208 '{"login":"human-dev","is_bot":false}' "$FLAGS_LABEL")" \
    "$(make_pr 209 "$APP" "$FLAGS_LABEL" '{"reviewRequests":[{"__typename":"User","login":"alice"}]}')" \
    "$(make_pr 219 "$APP" "$FLAGS_LABEL" '{"reviewRequests":[{"__typename":"Team","name":"Team Feature Flags","slug":"team-feature-flags"}]}')" \
    "$(make_pr 210 "$APP" "feature/cohorts")" \
    "$(make_pr 211 "$APP" "")" \
    "$(make_pr 212 "$APP" "")" \
    "$(make_pr 213 "$APP" "bug")" \
    "$(make_pr 214 "$APP" "")" \
    "$(make_pr 215 "$APP" "team/feature-flags")" \
    "$(make_pr 216 "$APP" "feature/feature-flags")" \
    "$(make_pr 217 "$APP" "feature/early-access-management")" \
    "$(make_pr 220 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 221 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 222 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 223 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 224 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 225 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 230 "$APP" "$FLAGS_LABEL" '{"assignees":[{"id":"U_1","login":"alice","name":"Alice"},{"id":"U_2","login":"outsider-dev","name":""},{"id":"U_3","login":"rubychilds","name":"Ruby"}]}')" \
    "$(make_pr 231 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 232 "$APP" "$FLAGS_LABEL" '{"assignees":[{"login":"alice"},{"login":"bob"},{"login":"carol"},{"login":"dave"}]}')" \
    "$(make_pr 218 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 226 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 227 "$APP" "$FLAGS_LABEL" '{"assignees":[{"login":"frank"}]}')" \
    "$(make_pr 228 "$APP" "$FLAGS_LABEL" '{"assignees":[{"login":"frank"}]}')" \
    "$(make_pr 229 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 240 "$APP" "$FLAGS_LABEL,stale" "$(jq -nc --arg c "$(created_ago 10)" '{createdAt: $c}')")" \
    "$(make_pr 250 "$APP" "")" \
    "$(make_pr 251 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 252 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 253 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 254 "$APP" "$FLAGS_LABEL")" \
    "$(make_pr 260 "$APP" "$FLAGS_LABEL" "$(jq -nc '{title: "Fix [the flag](https://example.com) | now\nsee ![x](https://example.com/x.png) <!here> @channel @@here @@@Everyone [a [b] c](https://evil.example)"}')")" \
)
write_fixture search.json "$search"

# A dropped PR still gets a flags file, so keeping it by mistake would land it
# in prs rather than hide it.
for number in 201 204 207 208 209 218 219 220 221 222 223 224 225 226 227 228 229 231 232 240 260; do
    write_files "$number" posthog/api/feature_flag.py
done
write_files 210 README.md docs/guide.md
for number in 215 216 217; do
    write_files "$number" README.md
done
write_files 211 frontend/src/scenes/feature-flags/FeatureFlag.tsx posthog/api/insight.py
write_files 212 frontend/src/lib/components/TaxonomicFilter/InfiniteList.tsx
write_files 213 posthog/api/insight.py
write_files 250 rust/flags-consumer/src/main.rs rust/flags-consumer/src/lib.rs README.md
write_files 251 products/cohort_many/d1/x.py products/cohort_many/d2/x.py products/cohort_many/d3/x.py \
    products/cohort_many/d4/x.py products/cohort_many/d5/x.py products/cohort_many/d6/x.py products/cohort_many/d7/x.py \
    products/cohort_many/d7/y.py
write_files 252 posthog/models/feature_flag/flag_matching.py posthog/models/feature_flag/flag_analytics.py README.md
write_files 253 posthog/models/cohort/util.py
write_files 254 products/feature_flags/backend/api/flags.py products/feature_flags/backend/api/test/test_flags.py
write_files 230 posthog/models/feature_flag/rollout.py

write_fixture timeline-220.json "$(json_list "$(review dave User approved)")"
write_fixture timeline-221.json "$(json_list "$(review erin User changes_requested)")"
write_fixture timeline-218.fail ""
write_fixture timeline-226.json "$(json_list "$(review dave User dismissed)")"
write_fixture timeline-227.json "$(json_list "$(review frank User commented)")"
write_fixture timeline-228.json "$(json_list "$(review frank User approved)")"
write_fixture commits-229.fail ""
write_fixture timeline-222.json "$(json_list \
    "$(review frank User commented)" \
    "$(review alice User commented)" \
    "$(review "copilot-pull-request-reviewer[bot]" Bot commented)")"
write_fixture timeline-223.json "$(json_list "$(review frank User commented)" "$(review dave User approved)")"
write_fixture timeline-224.json "$(json_list "$(review "stamphog[bot]" Bot approved)")"
write_fixture timeline-225.json "$(json_list "$(review "copilot-pull-request-reviewer[bot]" Bot commented)")"
write_fixture timeline-230.json "$(json_list "$(ready_event carol User)" "$(ready_event "ready-bot[bot]" Bot)")"
write_fixture timeline-231.json "$(json_list "$(ready_event carol User)")"

write_fixture commits-230.json "$(commit_list alice:User:2 zed:User "posthog[bot]:Bot" posthog-bot:User)"
write_fixture commits-231.json "$(commit_list bob:User)"
write_history posthog/models/cohort alice:User carol:User
write_history posthog/models/feature_flag \
    alice:User:2 bob:User zed:User:3 "posthog[bot]:Bot:3" :User:3 rubychilds:User:3
write_history products/cohort_many/d7 alice:User
write_history products/cohort_many/d1 alice:User
write_history products/cohort_many/d2 bob:User
write_history products/cohort_many/d6 carol:User:3
# The commits API returns a directory's subdirectory commits too, so the test
# directory's commits repeat in its parent's history.
write_history products/feature_flags/backend/api alice:User:2
write_history products/feature_flags/backend/api/test alice:User:2

run_helper

# ── Test: output shape ────────────────────────────────────────────────────

assert "helper exits 0" test "$helper_status" -eq 0
assert "helper prints one JSON object" prints_one_object
assert "output has exactly the documented top-level fields" \
    test "$(out 'keys')" = "$(jq -nc '["fetched", "capped", "roster", "prs", "commented", "reviewed", "outOfScope", "unfetched", "historyUnavailable"] | sort')"
assert "every prs entry has exactly the documented fields" \
    test "$(out '[.prs[] | keys] | unique')" = "[$PR_FIELDS]"
assert "a commented entry has the summary fields plus commenters, and no proposal" \
    test "$(out '[.commented[] | keys] | unique')" = "[$COMMENTED_FIELDS]"

# ── Test: queue search ────────────────────────────────────────────────────

assert "fetched counts every search result, including dropped PRs" \
    test "$(out '.fetched')" = "$(echo "$search" | jq 'length')"
assert "capped is false when fetched is under the limit" test "$(out '.capped')" = "false"
assert "the queue search asks for ready PRs only" \
    test "$(calls '[.[] | select(.[0:2] == ["pr", "list"]) | any(.[]; contains("draft:false"))] | any')" = "true"

assert "bot shape: an author with is_bot true is kept" test "$(placement 201)" = '["prs"]'
assert "bot shape: an app/ login is kept" test "$(placement 204)" = '["prs"]'
assert "bot shape: github-actions is kept" test "$(placement 207)" = '["prs"]'

assert "a kept PR's files are fetched, so the call log is live" test "$(files_calls 215)" = "1"
assert "a human-authored PR is dropped even with a flags label" test "$(placement 208)" = '[]'
assert "a human-authored PR's files are never fetched" test "$(files_calls 208)" = "0"
assert "a bot PR with a user review request is dropped" test "$(placement 209)" = '[]'
assert "a bot PR with a team review request is dropped" test "$(placement 219)" = '[]'
assert "a PR with a user review request never has its files fetched" test "$(files_calls 209)" = "0"
assert "a PR with a team review request never has its files fetched" test "$(files_calls 219)" = "0"

# ── Test: flags domain ────────────────────────────────────────────────────

for entry in 215:team/feature-flags 216:feature/feature-flags 210:feature/cohorts 217:feature/early-access-management; do
    assert "domain: the ${entry#*:} label alone puts a PR in scope" test "$(placement "${entry%%:*}")" = '["prs"]'
done
assert "domain: a label-only PR has no flags paths" test "$(pr 210 '.flagsPaths')" = "[]"
assert "domain: fileCount counts every changed file" test "$(pr 210 '.fileCount')" = "2"

assert "domain: a feature-flags scene path alone puts a PR in scope" test "$(placement 211)" = '["prs"]'
assert "domain: flagsPaths lists only the paths matching the net" \
    test "$(pr 211 '.flagsPaths')" = '["frontend/src/scenes/feature-flags/FeatureFlag.tsx"]'
assert "domain: a flags- crate path alone puts a PR in scope" test "$(placement 250)" = '["prs"]'
assert "domain: flagsPaths keeps every matching path" \
    test "$(pr 250 '.flagsPaths | sort')" = '["rust/flags-consumer/src/lib.rs","rust/flags-consumer/src/main.rs"]'

assert "out of scope: a PR with no flags path or label is listed nowhere" test "$(placement 212)" = '[]'
assert "out of scope: a non-flags label does not put a PR in scope" test "$(placement 213)" = '[]'
assert "out of scope: outOfScope counts those PRs and nothing else" test "$(out '.outOfScope')" = "2"

assert "unfetched: lists PRs whose files, timeline, or commits call failed" test "$(out '.unfetched')" = "[214,218,229]"
assert "unfetched: a PR whose files call failed appears in no other list" test "$(placement 214)" = '["unfetched"]'
assert "unfetched: a PR whose timeline call failed appears in no other list" test "$(placement 218)" = '["unfetched"]'
assert "unfetched: a PR whose commits call failed appears in no other list" test "$(placement 229)" = '["unfetched"]'
assert "historyUnavailable is empty when every commit-history call succeeds" test "$(out '.historyUnavailable')" = "[]"

# ── Test: review classification ───────────────────────────────────────────

assert "reviewed: a human approval moves the PR to reviewed only" test "$(placement 220)" = '["reviewed"]'
assert "reviewed: a human changes request moves the PR to reviewed only" test "$(placement 221)" = '["reviewed"]'
assert "reviewed: an approval wins over an earlier human comment" test "$(placement 223)" = '["reviewed"]'
assert "reviewed: an approval from someone behind the PR moves it to reviewed" test "$(placement 228)" = '["reviewed"]'
assert "reviewed: lists exactly the reviewed PRs" test "$(out '.reviewed | sort')" = "[220,221,223,228]"

assert "commented: a human comment-only review moves the PR to commented only" test "$(placement 222)" = '["commented"]'
assert "commented: commenters lists each human who commented, and no bot" \
    test "$(pr 222 '.commenters | sort')" = '["alice","frank"]'
assert "commented: a bot's comment-only review leaves the PR in prs" test "$(placement 225)" = '["prs"]'
assert "commented: a dismissed approval counts as a comment, not a review" test "$(placement 226)" = '["commented"]'
assert "commented: a comment from someone behind the PR leaves it in prs" test "$(placement 227)" = '["prs"]'

assert "botApproved: a bot approval keeps the PR in prs" test "$(placement 224)" = '["prs"]'
assert "botApproved: a bot approval sets botApproved" test "$(pr 224 '.botApproved')" = "true"
assert "botApproved: a bot comment does not set botApproved" test "$(pr 225 '.botApproved')" = "false"

# ── Test: humans behind the PR ────────────────────────────────────────────

assert "humans: an assignee who also committed is listed once with both sources" \
    test "$(human 230 alice '.via | sort')" = '["assignee","commit"]'
assert "humans: an assignee outside the roster is listed via assignee" \
    test "$(human 230 outsider-dev '.via')" = '["assignee"]'
assert "humans: a human who marked the PR ready is listed via marked-ready" \
    test "$(human 230 carol '.via')" = '["marked-ready"]'
assert "humans: a human commit author is listed via commit" test "$(human 230 zed '.via')" = '["commit"]'
assert "humans: a bot that marked the PR ready is not a human" \
    test "$(pr 230 'any(.humans[]; .login == "ready-bot[bot]")')" = "false"
assert "humans: a bot commit author is not a human" \
    test "$(pr 230 'any(.humans[]; .login == "posthog[bot]")')" = "false"
assert "humans: a bot on a user account is not a human" \
    test "$(pr 230 'any(.humans[]; .login == "posthog-bot")')" = "false"
assert "humans: each person appears once" test "$(pr 230 '[.humans[].login] | length == (unique | length)')" = "true"

# ── Test: per-PR fields ───────────────────────────────────────────────────

assert "bot is the author login" test "$(pr 215 '.bot')" = '"app/posthog"'
assert "title passes through" test "$(pr 215 '.title')" = '"Fix flags thing 215"'
assert "title: markdown links, pipes, newlines, and Slack pings in any case become plain text" \
    test "$(pr 260 '.title')" = '"Fix the flag now see x !here channel here Everyone [a [b] c] (https://evil.example)"'
assert "labels lists label names" test "$(pr 240 '.labels | sort')" = '["stale","team/feature-flags"]'
assert "stale is true for a PR with the stale label" test "$(pr 240 '.stale')" = "true"
assert "stale is false for a PR without the stale label" test "$(pr 215 '.stale')" = "false"
assert "ageDays counts whole days since creation" test "$(pr 240 '.ageDays')" = "10"
assert "ageDays is 1 for a PR created a day and a half ago" test "$(pr 215 '.ageDays')" = "1"

# ── Test: commit paths ────────────────────────────────────────────────────

assert "commit paths: two flags paths in one directory query it once" \
    test "$(calls_mentioning models/feature_flag)" = "1"
assert "commit paths: a PR with seven flags directories queries five" test "$(calls_mentioning cohort_many)" = "5"
assert "commit paths: the most-touched directory is among the five" test "$(calls_mentioning cohort_many/d7)" = "1"
assert "commit paths: a file whose directory is not a flags path is queried as the file" \
    test "$(calls_mentioning posthog/api/feature_flag.py)" = "1"
assert "commit paths: a subdirectory of another commit path is not queried on its own" \
    test "$(calls_mentioning products/feature_flags/backend/api)" = "1"

# ── Test: proposed reviewer ───────────────────────────────────────────────

assert "proposal: no one behind the PR is proposed, even the roster member with the most commits" \
    test "$(pr 230 '.proposal')" = '{"reason":"1 commit in these flags paths in 180 days","reviewer":"bob"}'
assert "proposal: a commit author or marked-ready human behind the PR is not proposed, and an unknown load ranks last" \
    test "$(pr 231 '.proposal')" = '{"reason":"no team commits in these flags paths; lowest review load (2)","reviewer":"alice"}'
assert "proposal: the team is proposed when every roster member is behind the PR" \
    test "$(pr 232 '.proposal')" = "{\"reason\":\"every team member is behind this PR\",\"reviewer\":$TEAM_REVIEWER}"
assert "proposal: only roster members' commits count, though outsider, bot, unlinked, and rubychilds commits each outnumber the winner's" \
    test "$(pr 252 '.proposal')" = '{"reason":"2 commits in these flags paths in 180 days","reviewer":"alice"}'
assert "proposal: commits add up across commit paths, and a path past the five-path cap counts for nothing" \
    test "$(pr 251 '.proposal')" = '{"reason":"2 commits in these flags paths in 180 days","reviewer":"alice"}'
assert "proposal: a commit tie goes to the lower review load" test "$(pr 253 '.proposal.reviewer')" = '"carol"'
assert "proposal: a commit in a subdirectory of a commit path counts once" \
    test "$(pr 254 '.proposal')" = '{"reason":"2 commits in these flags paths in 180 days","reviewer":"alice"}'
assert "proposal: with no commits, the lowest review load is proposed" \
    test "$(pr 215 '.proposal')" = '{"reason":"no team commits in these flags paths; lowest review load (0)","reviewer":"bob"}'

# ── Test: roster and review load ──────────────────────────────────────────

assert "roster lists team members without rubychilds" test "$(out '.roster | sort')" = '["alice","bob","carol","dave"]'
assert "review load is looked up once for each roster member" \
    test "$(load_logins)" = '["alice","bob","carol","dave"]'

# ── Test: read-only and trust fence ───────────────────────────────────────

assert "helper makes no gh call that could change state" test "$(write_calls)" = "0"
assert "trust fence: output has no body or message key anywhere" lacks_body_or_message_key
assert "trust fence: output does not contain the injected text" lacks_injection "$helper_out"
assert "trust fence: progress output does not contain the injected text" stderr_lacks_injection

# ── Test: roster call fails ───────────────────────────────────────────────

reset_fixtures
write_fixture search.json "$(json_list "$(make_pr 301 "$APP" "$FLAGS_LABEL" '{"assignees":[{"id":"U_1","login":"alice","name":"Alice"}]}')")"
write_files 301 posthog/api/feature_flag.py

run_helper

assert "roster failure: helper still exits 0" test "$helper_status" -eq 0
assert "roster failure: roster is null" test "$(out '.roster')" = "null"
assert "roster failure: in-scope PRs are still listed" test "$(placement 301)" = '["prs"]'
assert "roster failure: the team is proposed" \
    test "$(pr 301 '.proposal')" = "{\"reason\":\"team roster unavailable\",\"reviewer\":$TEAM_REVIEWER}"

# ── Test: unlinked commit authors and failed load lookups ─────────────────

reset_fixtures
write_members alice bob
write_fixture search.json "$(json_list "$(make_pr 401 "$APP" "$FLAGS_LABEL")")"
write_files 401 posthog/models/feature_flag/flag_matching.py
write_fixture commits-401.json "$(commit_list ":User" alice:User)"

run_helper

assert "unlinked author: helper exits 0" test "$helper_status" -eq 0
assert "unlinked author: a commit with no linked account adds no human" \
    test "$(pr 401 '[.humans[].login]')" = '["alice"]'
assert "unknown load: the reason says so when the proposed member's lookup failed" \
    test "$(pr 401 '.proposal')" = '{"reason":"no team commits in these flags paths; lowest review load (unknown)","reviewer":"bob"}'

# ── Test: commit-history call fails ───────────────────────────────────────

reset_fixtures
write_members alice bob
write_load alice 1
write_load bob 0
write_fixture search.json "$(json_list "$(make_pr 501 "$APP" "$FLAGS_LABEL")" "$(make_pr 502 "$APP" "$FLAGS_LABEL")")"
write_files 501 posthog/models/feature_flag/flag_matching.py
write_files 502 posthog/models/cohort/util.py
fail_history posthog/models/feature_flag
write_history posthog/models/cohort alice:User

run_helper

assert "history failure: helper exits 0" test "$helper_status" -eq 0
assert "history failure: historyUnavailable lists the path whose call failed" \
    test "$(out '.historyUnavailable')" = '["posthog/models/feature_flag"]'
assert "history failure: the reason says the history failed instead of claiming no commits" \
    test "$(pr 501 '.proposal')" = '{"reason":"no team commits in these flags paths; lowest review load (0); some commit history failed to load","reviewer":"bob"}'
assert "history failure: a PR whose history loaded keeps its plain reason" \
    test "$(pr 502 '.proposal')" = '{"reason":"1 commit in these flags paths in 180 days","reviewer":"alice"}'

# ── Test: empty search ────────────────────────────────────────────────────

reset_fixtures
write_members alice
write_fixture search.json "[]"

run_helper

assert "empty search: helper exits 0" test "$helper_status" -eq 0
assert "empty search: empty lists, zero counts, and no cap" \
    test "$(out '[.fetched, .capped, .prs, .commented, .reviewed, .outOfScope, .unfetched, .historyUnavailable]')" = "[0,false,[],[],[],0,[],[]]"

# ── Test: search cap ──────────────────────────────────────────────────────

# Human authors keep the helper from making any per-PR call.
reset_fixtures
write_members alice
write_fixture search.json "$(jq -nc --arg created "$(created_ago 1)" '[range(0; 1000) | {
    number: (5000 + .), title: "Human PR", author: {login: "human-dev", is_bot: false},
    headRefName: "human/branch", createdAt: $created, labels: [], assignees: [], reviewRequests: []
}]')"

run_helper

assert "cap: capped is true when fetched reaches the 1000 limit" test "$(out '[.fetched, .capped]')" = "[1000,true]"

# ── Results ───────────────────────────────────────────────────────────────

print_results
