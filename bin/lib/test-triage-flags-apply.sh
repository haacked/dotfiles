#!/bin/bash
# Tests for bin/triage-flags-apply, run against a stub gh that serves raw
# GitHub API responses from fixtures. The assertions read only the helper's
# stdout JSON and the log of gh calls it made.
#
# Usage: test-triage-flags-apply.sh

# shellcheck disable=SC2016 # jq filters contain a literal $.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/test-triage-stub.sh
source "$SCRIPT_DIR/test-triage-stub.sh"

HELPER="$SCRIPT_DIR/../triage-flags-apply"

# A missing view or user fixture fails the call. A missing reviews fixture
# serves an empty list. A .fail marker fails a view, reviews, or edit call. A
# user .404 marker prints GitHub's error body to stdout and fails, as gh does.
write_gh_stub <<'DISPATCH'
reviews_re='^repos/PostHog/posthog/pulls/([0-9]+)/reviews$'
users_re='^users/(.+)$'

[[ "$1 ${2-}" == "pr view" ]] && serve_unless_failed "$fixtures/pr-$3.json"
[[ "$1 ${2-}" == "issue view" ]] && serve_unless_failed "$fixtures/issue-$3.json"
if [[ "$1 ${2-}" == "pr edit" || "$1 ${2-}" == "issue edit" ]]; then
    if [[ -f "$fixtures/edit-$3.fail" ]]; then
        echo "GraphQL: Could not add the reviewer (addReviewers)" >&2
        echo "second line of the error" >&2
        exit 1
    fi
    echo "https://github.com/PostHog/posthog/pull/$3"
    exit 0
fi
[[ "$endpoint" =~ $reviews_re ]] && serve_unless_failed "$fixtures/reviews-${BASH_REMATCH[1]}.json" '[]'
if [[ "$endpoint" =~ $users_re ]]; then
    if [[ -f "$fixtures/user-${BASH_REMATCH[1]}.404" ]]; then
        echo '{"message":"Not Found","documentation_url":"https://docs.github.com/rest","status":"404"}'
        exit 1
    fi
    serve "$fixtures/user-${BASH_REMATCH[1]}.json"
fi
DISPATCH

# ── Fixture builders ──────────────────────────────────────────────────────

TEAM="PostHog/team-feature-flags"

write_pr() { # number [json merged over the defaults]
    local overrides="${2:-}"
    [[ -n "$overrides" ]] || overrides='{}'
    jq -nc --argjson n "$1" --argjson overrides "$overrides" '{
        number: $n,
        state: "OPEN",
        isDraft: false,
        reviewRequests: [],
        title: "Fix flags thing \($n)",
        url: "https://github.com/PostHog/posthog/pull/\($n)"
    } + $overrides' >"$FIXTURES/pr-$1.json"
}

write_issue() { # number [json merged over the defaults]
    local overrides="${2:-}"
    [[ -n "$overrides" ]] || overrides='{}'
    jq -nc --argjson n "$1" --arg body "$INJECTION" --argjson overrides "$overrides" '{
        number: $n,
        state: "OPEN",
        assignees: [],
        title: "Flag bug \($n)",
        body: $body,
        url: "https://github.com/PostHog/posthog/issues/\($n)"
    } + $overrides' >"$FIXTURES/issue-$1.json"
}

rest_review() { # login user-type state
    jq -nc --arg login "$1" --arg type "$2" --arg state "$3" --arg body "$INJECTION" \
        '{id: 1, user: {login: $login, type: $type}, state: $state, body: $body, commit_id: "abc"}'
}

write_user() { # login name
    jq -nc --arg login "$1" --arg name "$2" --arg bio "$INJECTION" \
        '{login: $login, name: (if $name == "" then null else $name end), bio: $bio, type: "User"}' \
        >"$FIXTURES/user-$1.json"
}

# ── Reading the helper's output ───────────────────────────────────────────

item() { # list kind number filter
    out --arg list "$1" --arg kind "$2" --argjson n "$3" \
        "[.[\$list][] | select(.kind == \$kind and .number == \$n)] | first | $4"
}

edit_calls() {
    calls '[.[] | select(.[0:2] | join(" ") | IN("pr edit", "issue edit")) | join(" ")] | sort'
}

user_lookups() {
    calls '[.[] | .[] | select(startswith("users/")) | ltrimstr("users/")] | sort'
}

# Counts calls other than the views, edits, and GET api calls the helper may
# make. gh api sends POST when given fields and no explicit method.
other_calls() {
    calls '[.[] | select(
        (.[0:2] | join(" ") | IN("pr view", "issue view", "pr edit", "issue edit") | not)
        and (.[0] != "api" or any(.[]; IN("-X", "--method", "-f", "-F", "--field", "--raw-field", "--input")))
    )] | length'
}

# ── Main scenario fixtures ────────────────────────────────────────────────
#
# 301      PR to alice; only bots approved and a human commented (applied)
# 302-309  PRs that changed since the queue listed them (skipped)
# 310      PR whose edit fails
# 311      PR to the team
# 312      PR to carol, whose profile lookup returns 404
# 401      issue to bob, given as @bob, whose profile has no name (applied)
# 402, 403 issues that changed (skipped)
# 404      issue to alice (applied)
# 406      issue whose view fails (skipped)

reset_fixtures
write_user alice "Alice Smith"
write_user bob ""
: >"$FIXTURES/user-carol.404"

write_pr 301 "$(jq -nc '{title: "Fix [the flag](https://example.com) | now\nsee <!here> @@channel"}')"
write_fixture reviews-301.json "$(json_list \
    "$(rest_review "stamphog[bot]" Bot APPROVED)" \
    "$(rest_review posthog-bot User APPROVED)" \
    "$(rest_review frank User COMMENTED)")"
write_pr 302 '{"state":"CLOSED"}'
write_pr 303 '{"state":"MERGED"}'
write_pr 304 '{"isDraft":true}'
write_pr 305 '{"reviewRequests":[{"__typename":"User","login":"bob"},{"__typename":"Team","name":"Team Feature Flags","slug":"team-feature-flags"}]}'
write_pr 306
write_fixture reviews-306.json "$(json_list "$(rest_review frank User APPROVED)" "$(rest_review gina User APPROVED)")"
write_pr 307
write_fixture reviews-307.json "$(json_list "$(rest_review frank User CHANGES_REQUESTED)")"
write_pr 308
write_fixture reviews-308.fail ""
write_pr 310
write_fixture edit-310.fail ""
write_pr 311
write_pr 312
write_issue 401
write_issue 402 '{"state":"CLOSED"}'
write_issue 403 '{"assignees":[{"login":"matheus-vb"}]}'
write_issue 404

run_helper \
    pr:301=alice pr:302=dave pr:303=dave pr:304=dave pr:305=dave pr:306=dave pr:307=dave pr:308=dave \
    pr:309=dave pr:310=alice "pr:311=$TEAM" pr:312=carol \
    issue:401=@bob issue:402=dave issue:403=dave issue:404=alice issue:406=dave \
    "issue:405=$TEAM" pr:abc=alice "pr:407=bad;login" pr:408=-alice foo:409=alice pr:410 \
    pr:0=alice pr:320=alice pr:320=bob

# ── Test: output shape ────────────────────────────────────────────────────

assert "helper exits 0" test "$helper_status" -eq 0
assert "helper prints one JSON object" prints_one_object
assert "output has exactly the documented top-level fields" \
    test "$(out 'keys')" = "$(jq -nc '["dryRun", "applied", "wouldApply", "skipped", "failed", "invalid", "report"] | sort')"
assert "dryRun is false without --dry-run" test "$(out '.dryRun')" = "false"
assert "wouldApply is empty without --dry-run" test "$(out '.wouldApply')" = "[]"

# ── Test: applied ─────────────────────────────────────────────────────────

assert "applied: lists exactly the items that passed their checks and were edited" \
    test "$(out '[.applied[] | "\(.kind):\(.number)=\(.login)"]')" \
    = "[\"pr:301=alice\",\"pr:311=$TEAM\",\"pr:312=carol\",\"issue:401=bob\",\"issue:404=alice\"]"
assert "applied: an entry has kind, number, login, title, and url" \
    test "$(out '[.applied[] | keys] | unique')" = '[["kind","login","number","title","url"]]'
assert "applied: bot approvals and a human comment do not block a request" \
    test "$(item applied pr 301 '.login')" = '"alice"'
assert "applied: a leading @ is stripped from the login" test "$(item applied issue 401 '.login')" = '"bob"'
assert "applied: the url comes from GitHub" \
    test "$(item applied issue 404 '.url')" = '"https://github.com/PostHog/posthog/issues/404"'
assert "applied: titles are reduced to plain text" \
    test "$(item applied pr 301 '.title')" = '"Fix the flag now see !here channel"'

assert "edits: one edit per item that passed its checks, with the approved login" \
    test "$(edit_calls)" = "$(jq -nc --arg team "$TEAM" '[
        "issue edit 401 --repo PostHog/posthog --add-assignee bob",
        "issue edit 404 --repo PostHog/posthog --add-assignee alice",
        "pr edit 301 --repo PostHog/posthog --add-reviewer alice",
        "pr edit 310 --repo PostHog/posthog --add-reviewer alice",
        "pr edit 311 --repo PostHog/posthog --add-reviewer \($team)",
        "pr edit 312 --repo PostHog/posthog --add-reviewer carol"
    ] | sort')"
assert "edits: the helper makes no other call that could change state" test "$(other_calls)" = "0"

# ── Test: skipped ─────────────────────────────────────────────────────────

assert "skipped: a closed PR" test "$(item skipped pr 302 '.reason')" = '"the PR is closed"'
assert "skipped: a merged PR" test "$(item skipped pr 303 '.reason')" = '"the PR is merged"'
assert "skipped: a draft PR" test "$(item skipped pr 304 '.reason')" = '"the PR is a draft"'
assert "skipped: a PR with a user or team review request" \
    test "$(item skipped pr 305 '.reason')" = '"review already requested from bob, team-feature-flags"'
assert "skipped: a PR a human approved" \
    test "$(item skipped pr 306 '.reason')" = '"already reviewed by frank, gina"'
assert "skipped: a PR a human requested changes on" \
    test "$(item skipped pr 307 '.reason')" = '"already reviewed by frank"'
assert "skipped: a PR whose reviews could not be read" \
    test "$(item skipped pr 308 '.reason | startswith("could not read the reviews: ")')" = "true"
assert "skipped: a PR that could not be read" \
    test "$(item skipped pr 309 '.reason | startswith("could not read the PR: ")')" = "true"
assert "skipped: a closed issue" test "$(item skipped issue 402 '.reason')" = '"the issue is closed"'
assert "skipped: an assigned issue" test "$(item skipped issue 403 '.reason')" = '"already assigned to matheus-vb"'
assert "skipped: an issue that could not be read" \
    test "$(item skipped issue 406 '.reason | startswith("could not read the issue: ")')" = "true"
assert "skipped: an entry has kind, number, login, and reason" \
    test "$(out '[.skipped[] | keys] | unique')" = '[["kind","login","number","reason"]]'
assert "skipped: lists exactly the items that changed or could not be checked" \
    test "$(out '[.skipped[] | "\(.kind):\(.number)"]')" \
    = '["pr:302","pr:303","pr:304","pr:305","pr:306","pr:307","pr:308","pr:309","issue:402","issue:403","issue:406"]'

# ── Test: failed ──────────────────────────────────────────────────────────

assert "failed: a failed edit lists its exit status and the first line of its error" \
    test "$(item failed pr 310 '.')" \
    = '{"error":"GraphQL: Could not add the reviewer (addReviewers)","kind":"pr","login":"alice","number":310,"status":1}'
assert "failed: lists only the failed edit" test "$(out '[.failed[].number]')" = "[310]"

# ── Test: invalid ─────────────────────────────────────────────────────────

assert "invalid: lists every malformed or ambiguous argument, in order" \
    test "$(out '[.invalid[].arg]')" = "$(jq -nc --arg team "$TEAM" \
        '["issue:405=\($team)", "pr:abc=alice", "pr:407=bad;login", "pr:408=-alice", "foo:409=alice", "pr:410", "pr:0=alice", "pr:320=alice", "pr:320=bob"]')"
assert "invalid: an issue cannot be assigned to a team" \
    test "$(out --arg arg "issue:405=$TEAM" '.invalid[] | select(.arg == $arg) | .reason')" = '"an issue cannot be assigned to a team"'
assert "invalid: a number named twice rejects both entries" \
    test "$(out '[.invalid[] | select(.arg | startswith("pr:320=")) | .reason] | unique')" = '["number 320 appears more than once"]'
assert "invalid: an invalid argument makes no gh call" \
    test "$(calls '[.[] | select(any(.[]; test("(^|/)(405|407|408|409|410|320)$")))] | length')" = "0"

# ── Test: report ──────────────────────────────────────────────────────────

assert "report: the date is today's" test "$(out '.report.date')" = "\"$(date "+%b %-d")\""
assert "report: people are the applied logins, ordered ignoring case" \
    test "$(out '[.report.people[].login]')" = "[\"alice\",\"bob\",\"carol\",\"$TEAM\"]"
assert "report: a person lists reviews and issues by number" \
    test "$(out '.report.people[0]')" = "$(jq -nc '{
        login: "alice", name: "Alice Smith",
        reviews: [{number: 301, title: "Fix the flag now see !here channel", url: "https://github.com/PostHog/posthog/pull/301"}],
        issues: [{number: 404, title: "Flag bug 404", url: "https://github.com/PostHog/posthog/issues/404"}]
    }' | jq -Sc .)"
assert "report: a profile with no name gives a null name" test "$(out '.report.people[1].name')" = "null"
assert "report: a profile lookup that returns 404 gives a null name" test "$(out '.report.people[2].name')" = "null"
assert "report: the team has a null name" test "$(out '.report.people[3].name')" = "null"
assert "report: profiles are looked up once for each applied login, and never for the team or a skipped login" \
    test "$(user_lookups)" = '["alice","bob","carol"]'

# ── Test: trust fence ─────────────────────────────────────────────────────

assert "trust fence: output has no body or message key anywhere" lacks_body_or_message_key
assert "trust fence: output does not contain the injected text" lacks_injection "$helper_out"
assert "trust fence: progress output does not contain the injected text" stderr_lacks_injection

# ── Test: --dry-run ───────────────────────────────────────────────────────

reset_fixtures
write_user alice "Alice Smith"
write_pr 501
write_pr 502 '{"isDraft":true}'
write_issue 601

run_helper --dry-run pr:501=alice pr:502=alice issue:601=alice

assert "dry run: helper exits 0" test "$helper_status" -eq 0
assert "dry run: dryRun is true" test "$(out '.dryRun')" = "true"
assert "dry run: makes no edit" test "$(edit_calls)" = "[]"
assert "dry run: wouldApply lists the items that passed their checks" \
    test "$(out '[.wouldApply[] | "\(.kind):\(.number)"]')" = '["pr:501","issue:601"]'
assert "dry run: applied is empty" test "$(out '.applied')" = "[]"
assert "dry run: items that changed are still skipped" test "$(out '[.skipped[].number]')" = "[502]"
assert "dry run: the report previews the items that would apply" \
    test "$(out '[.report.people[] | .login, [.reviews[].number], [.issues[].number]]')" = '["alice",[501],[601]]'

# ── Test: arguments ───────────────────────────────────────────────────────

reset_fixtures
run_helper
assert "no items: the helper exits 2" test "$helper_status" -eq 2

reset_fixtures
run_helper pr:abc=alice
assert "only invalid items: helper exits 0" test "$helper_status" -eq 0
assert "only invalid items: the helper makes no gh call" test "$(calls 'length')" = "0"
assert "only invalid items: every list but invalid is empty and the report has no people" \
    test "$(out '[.applied, .skipped, .failed, .report.people]')" = "[[],[],[],[]]"

# ── Results ───────────────────────────────────────────────────────────────

print_results
