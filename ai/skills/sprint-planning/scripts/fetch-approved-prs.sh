#!/bin/bash
# List open PRs the current user has approved but that have not yet been merged,
# across all repositories under SPRINT_ORG. A PR qualifies when the user's latest
# opinionated review (comment-only reviews ignored) is APPROVED and the PR is
# still open. So approve-then-comment still counts; approve-then-request-changes
# does not. The batched GraphQL lookup is delegated to batch-item-query.sh.
#
# Usage: fetch-approved-prs.sh
#
# Output: JSON array sorted by most recently updated, each:
#   { title, url, repository, number, isDraft, updatedAt, author }
# Returns [] when nothing matches.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
BATCH_QUERY="$SCRIPT_DIR/batch-item-query.sh"

me=$(gh api user --jq .login)

# Narrow to open PRs the user has reviewed in any way; the GraphQL pass below
# keeps only those whose latest opinionated review by the user is an approval.
prs=$(gh search prs \
  --reviewed-by="$me" \
  --state=open \
  --owner="$SPRINT_ORG" \
  --limit=100 \
  --json number,title,url,repository,isDraft,updatedAt)

if [[ "$(echo "$prs" | jq 'length')" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

refs=$(echo "$prs" | jq '[.[] | {
  owner: (.repository.nameWithOwner | split("/")[0]),
  repo: .repository.name,
  type: "PullRequest",
  number
}]')

response=$(echo "$refs" | "$BATCH_QUERY" \
  "author { login } latestOpinionatedReviews(first: 50) { nodes { author { login } state } }" \
  "title")

if [[ -z "$response" ]]; then
  echo "[]"
  exit 0
fi

# Join the GraphQL response back onto the search results by index (both are in
# input order) and keep PRs whose latest opinionated review by the user approved.
echo "$prs" | jq --argjson resp "$response" --arg me "$me" '
  [to_entries[] |
    .key as $i | .value as $it |
    $resp.data["item_\($i)"].pullRequest as $pr |
    select($pr.latestOpinionatedReviews.nodes
      | any(.author.login == $me and .state == "APPROVED")) |
    {
      title: $it.title,
      url: $it.url,
      repository: $it.repository.nameWithOwner,
      number: $it.number,
      isDraft: $it.isDraft,
      updatedAt: $it.updatedAt,
      author: $pr.author.login
    }
  ]
  | sort_by(.updatedAt) | reverse
'
