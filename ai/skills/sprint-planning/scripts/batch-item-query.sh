#!/bin/bash
# Resolve fields for many GitHub issues/PRs in one batched GraphQL query,
# replacing N REST calls with a single request. Shared by the sprint-planning
# and sprint-status helper scripts, which each build their own input array and
# join the response back by index.
#
# Usage:
#   echo '<json-array>' | batch-item-query.sh "<pr_fields>" "<issue_fields>"
#
# Stdin: JSON array of items, each: { owner, repo, type, number }
#   where type is "PullRequest" or "Issue". Extra fields are ignored.
# Args:
#   $1 pr_fields    - GraphQL selection set for pull requests,
#                     e.g. "state isDraft title"
#   $2 issue_fields - GraphQL selection set for issues,
#                     e.g. "state stateReason title"
#
# Output: the raw GraphQL response JSON. Each input item is aliased
#   item_<index> (matching input order) under .data, so callers join by index.
#   Prints nothing (empty string) when the input is empty or the query fails
#   entirely, including when no .data is returned, so callers apply their own
#   fallback. A batch where only some items fail still returns .data with the
#   resolved items present and the failed ones null.

set -euo pipefail

pr_fields="${1:?pr_fields required}"
issue_fields="${2:?issue_fields required}"

items="$(cat)"

count=$(echo "$items" | jq 'length')
if [[ "$count" -eq 0 ]]; then
  exit 0
fi

# owner/repo are escaped with @json so a malformed value can't break out of
# the query string; number is a jq number, emitted as bare digits.
query=$(echo "$items" | jq -r --arg pr "$pr_fields" --arg issue "$issue_fields" '
  [to_entries[] |
    .key as $i | .value as $it |
    "item_\($i): repository(owner: \($it.owner | @json), name: \($it.repo | @json)) { " +
    (if $it.type == "PullRequest" then
       "pullRequest(number: \($it.number)) { \($pr) }"
     else
       "issue(number: \($it.number)) { \($issue) }"
     end) + " }"
  ] | "query { " + join(" ") + " }"
')

response=$(gh api graphql -f query="$query" 2>/dev/null) || true

# Keep partial data (some items resolved, others null); only stay silent when
# there is no .data at all.
if jq -e '.data' <<<"$response" >/dev/null 2>&1; then
  printf '%s' "$response"
fi
