#!/bin/bash
# Tests for is_copilot_review_pending in copilot.sh and the branch it drives in
# get_copilot_review_for_head, its only caller.
#
# The function reads the PR's review requests over GraphQL because REST's
# requested_reviewers returns only `.users`: Copilot is a GitHub App, its entry
# is a Bot node, and the REST list reads empty for the whole time Copilot is
# mid-review. These tests pin the Bot case, the login aliases the match accepts,
# the entries it must reject, the "not pending" reading of an API failure, and
# the two outcomes the caller draws from the answer.
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
GH_ERROR_BODY='{"message":"Not Found","status":"404"}'

gh() {
  printf '%s\n' "$*" >> "$GH_CALLS_FILE"
  if [[ "$GH_STATUS" -ne 0 ]]; then
    printf '%s\n' "$GH_ERROR_BODY"
    return "$GH_STATUS"
  fi
  local filter=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --jq)
        filter="$2"
        shift 2
        ;;
      *) shift ;;
    esac
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

# ── Test: a requested Copilot Bot node reads as pending ───────────────────
# The bug this fix closes: REST reported {"users":[],"teams":[]} here.

response_with "$(bot copilot-pull-request-reviewer)"
assert "requested Copilot bot is pending" is_copilot_review_pending
assert "asks GraphQL, not the REST requested_reviewers list" gh_asked_graphql
assert "splits REPO into owner and name and passes the PR number" gh_passed_pr_coordinates

# ── Test: the login aliases GitHub reports Copilot under ──────────────────

response_with "$(bot Copilot)"
assert "the Copilot alias is pending" is_copilot_review_pending

response_with "$(bot 'copilot-pull-request-reviewer[bot]')"
assert "the [bot]-suffixed login is pending" is_copilot_review_pending

# ── Test: nothing requested ───────────────────────────────────────────────

response_with ""
assert_not "no requested reviewers is not pending" is_copilot_review_pending

# ── Test: reviewers that are not Copilot ──────────────────────────────────

response_with "$(user octocat)"
assert_not "a requested human is not pending" is_copilot_review_pending

response_with "$(user copilot-fan)"
assert_not "a human handle containing copilot is not pending" is_copilot_review_pending

response_with "$(bot greptile-apps)"
assert_not "a different review bot is not pending" is_copilot_review_pending

response_with '{"requestedReviewer":{"__typename":"Team","name":"Reviewers","slug":"reviewers"}}'
assert_not "a requested team is not pending" is_copilot_review_pending

response_with '{"requestedReviewer":null}'
assert_not "a null reviewer node is not pending" is_copilot_review_pending

# ── Test: Copilot alongside other reviewers ───────────────────────────────

response_with "$(user octocat),$(bot copilot-pull-request-reviewer)"
assert "Copilot among other reviewers is pending" is_copilot_review_pending

# ── Test: an API failure reads as not pending, quietly ────────────────────
# gh writes HTTP error bodies to stdout, so the "0" fallback has to replace the
# captured body rather than be appended to it: the function's `-gt` test errors
# out loudly on a captured body it cannot read as a number.

stderr_file="$TESTTMP/stderr"
GH_STATUS=22
rc=0
is_copilot_review_pending 2>"$stderr_file" || rc=$?
assert "an API failure is not pending" test "$rc" -ne 0
assert "an API failure stays quiet" test ! -s "$stderr_file"
GH_STATUS=0

# ── Caller: what get_copilot_review_for_head does with the answer ─────────
# Reading "not pending" while Copilot was mid-review sent it down the request
# branch, where a PR with no earlier Copilot review then failed the enabled
# check and returned 2 — so copilot-review-loop.sh gave up on the very first
# review of every PR. POLL_TIMEOUT=0 skips the polling loop, leaving only the
# branch under test; a timeout there returns 1.

POLL_TIMEOUT=0
requested_count=0
HEAD_SHA="abc1234"
LATEST_REVIEW='{"id":null,"commit_id":null}'

get_pr_head_sha() { echo "$HEAD_SHA"; }
get_latest_copilot_review() { echo "$LATEST_REVIEW"; }
request_copilot_review() {
  requested_count=$((requested_count + 1))
  return 0
}

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

# ── Results ───────────────────────────────────────────────────────────────

print_results
