#!/bin/bash
# Tests for is_copilot_review_pending in copilot.sh and the branch it drives in
# get_copilot_review_for_head, its only caller.
#
# Usage: test-copilot-pending.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/logging.sh
source "$SCRIPT_DIR/logging.sh"
# shellcheck source=bin/lib/copilot.sh
source "$SCRIPT_DIR/copilot.sh"

TESTTMP="$(mktemp -d)"
trap 'rm -rf "$TESTTMP"' EXIT

# ── Fixture globals the function reads ────────────────────────────────────

REPO="acme/widgets"
PR_NUMBER=123

# ── gh stub ───────────────────────────────────────────────────────────────
# Defined after sourcing so it wins. Nothing hits the network: the stub records
# the call, then answers GH_RESPONSE through the function's own --jq filter with
# real jq, so the tests exercise the production projection rather than a canned
# count. GH_STATUS non-zero behaves like a failed `gh api`, which writes the HTTP
# error body to stdout.
#
# The calls go to a file, not a variable: the function captures gh in a command
# substitution, and that subshell's variables die with it.

GH_CALLS_FILE="$TESTTMP/gh-calls"
: > "$GH_CALLS_FILE"
GH_RESPONSE=""
GH_STATUS=0

gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  if [[ "$GH_STATUS" -ne 0 ]]; then
    printf '%s\n' '{"message":"Not Found","status":"404"}'
    return "$GH_STATUS"
  fi
  local filter=""
  while [[ $# -gt 0 ]]; do
    [[ "$1" == "--jq" ]] && filter="$2"
    shift
  done
  printf '%s' "$GH_RESPONSE" | jq -r "$filter"
}

# A reviewRequests response wrapping the given reviewer nodes.
response_with() {
  GH_RESPONSE=$(printf \
    '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[%s]}}}}}' "$1")
}

bot() { printf '{"requestedReviewer":{"__typename":"Bot","login":"%s"}}' "$1"; }
user() { printf '{"requestedReviewer":{"__typename":"User","login":"%s"}}' "$1"; }

gh_asked_graphql() {
  local calls
  calls=$(cat "$GH_CALLS_FILE")
  [[ "$calls" == *graphql* && "$calls" == *reviewRequests* && "$calls" != *requested_reviewers* ]]
}

gh_passed_pr_coordinates() {
  local calls
  calls=$(cat "$GH_CALLS_FILE")
  [[ "$calls" == *"owner=acme"* && "$calls" == *"name=widgets"* && "$calls" == *"pr=123"* ]]
}

# Assert what is_copilot_review_pending makes of a response holding $2's nodes.
assert_pending() { response_with "$2"; assert "$1" is_copilot_review_pending; }
assert_not_pending() { response_with "$2"; assert_not "$1" is_copilot_review_pending; }

# ── Test: a requested Copilot Bot node reads as pending ───────────────────

assert_pending "requested Copilot bot is pending" "$(bot copilot-pull-request-reviewer)"
assert "asks GraphQL, not the REST requested_reviewers list" gh_asked_graphql
assert "splits REPO into owner and name and passes the PR number" gh_passed_pr_coordinates

# ── Test: the login aliases GitHub reports Copilot under ──────────────────

assert_pending "the Copilot alias is pending" "$(bot Copilot)"
assert_pending "the [bot]-suffixed login is pending" "$(bot 'copilot-pull-request-reviewer[bot]')"

# ── Test: nothing requested ───────────────────────────────────────────────

assert_not_pending "no requested reviewers is not pending" ""

# ── Test: reviewers that are not Copilot ──────────────────────────────────

assert_not_pending "a requested human is not pending" "$(user octocat)"
assert_not_pending "a human handle containing copilot is not pending" "$(user copilot-fan)"
assert_not_pending "a different review bot is not pending" "$(bot greptile-apps)"
assert_not_pending "a requested team is not pending" \
  '{"requestedReviewer":{"__typename":"Team","name":"Reviewers","slug":"reviewers"}}'
assert_not_pending "a null reviewer node is not pending" '{"requestedReviewer":null}'

# ── Test: Copilot alongside other reviewers ───────────────────────────────

assert_pending "Copilot among other reviewers is pending" \
  "$(user octocat),$(bot copilot-pull-request-reviewer)"

# ── Test: the shape check-pending-reviews.sh feeds pending-reviews.jq ─────
# Only .login is read here, but the other consumer selects on .type, so nothing
# else in either suite would notice the projection dropping it.

response_with "$(user octocat),$(bot greptile-apps)"
assert "projects login and GraphQL __typename as type" \
  test "$(get_requested_reviewers "$REPO" "$PR_NUMBER" | jq -c .)" \
  = '[{"login":"octocat","type":"User"},{"login":"greptile-apps","type":"Bot"}]'

# ── Test: an API failure reads as not pending, and says so ────────────────
# gh writes HTTP error bodies to stdout, so a failed fetch must not be read as
# an answer: the count runs on the captured list only after the fetch succeeds.
# The warning belongs on stderr, since get_copilot_review_for_head returns the
# review ID on stdout.

stdout_file="$TESTTMP/stdout"
stderr_file="$TESTTMP/stderr"
GH_STATUS=22
rc=0
is_copilot_review_pending >"$stdout_file" 2>"$stderr_file" || rc=$?
assert "an API failure is not pending" test "$rc" -ne 0
assert "an API failure warns why" \
  grep -q "Could not check for a pending Copilot review" "$stderr_file"
assert "the warning stays off stdout" test ! -s "$stdout_file"
GH_STATUS=0

# ── Caller: what get_copilot_review_for_head does with the answer ─────────
# POLL_TIMEOUT=0 skips the polling loop, leaving only the branch under test; a
# timeout there returns 1.

POLL_TIMEOUT=0
requested_count=0

get_pr_head_sha() { echo "abc1234"; }
get_latest_copilot_review() { echo '{"id":null,"commit_id":null}'; }
request_copilot_review() {
  requested_count=$((requested_count + 1))
  return 0
}

# These three stubs are never restored, so anything added below runs against
# them. Keep this the last section in the file.

# Copilot mid-review on a PR it has never reviewed before.
response_with "$(bot copilot-pull-request-reviewer)"
rc=0
get_copilot_review_for_head >/dev/null 2>&1 || rc=$?
assert "waits for a pending review instead of reporting Copilot disabled" test "$rc" -ne 2
assert "does not re-request a review that is already pending" test "$requested_count" -eq 0

# Nothing pending after a successful request: Copilot really is off for this repo.
response_with ""
requested_count=0
rc=0
get_copilot_review_for_head >/dev/null 2>&1 || rc=$?
assert "requests a review when none is pending" test "$requested_count" -eq 1
assert "still reports Copilot disabled when the request leaves nothing pending" test "$rc" -eq 2

# A reviewer list that cannot be read is not evidence Copilot is off: the
# request above succeeded, so only the confirmation failed.
response_with ""
GH_STATUS=22
requested_count=0
rc=0
get_copilot_review_for_head >/dev/null 2>"$stderr_file" || rc=$?
assert "a fetch failure is not reported as Copilot being disabled" test "$rc" -ne 2
assert "a fetch failure warns why" \
  grep -q "Could not check for a pending Copilot review" "$stderr_file"
assert_not "a fetch failure does not advise changing repository settings" \
  grep -q "does not appear to be enabled" "$stderr_file"
GH_STATUS=0

# ── Results ───────────────────────────────────────────────────────────────

print_results
