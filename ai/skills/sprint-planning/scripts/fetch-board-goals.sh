#!/bin/bash
# Fetch In Progress and Todo items from the project board with assignee
# information. Uses a single batched GraphQL query to resolve assignees
# for all linkable items (Issues and PRs), keeping API calls to a minimum.
#
# Usage: fetch-board-goals.sh
#
# Output: JSON array of items with fields:
#   id, title, status, url, type, number, assignees
#
# Draft items (no linked Issue/PR) have null url, type, number,
# and an empty assignees array.
#
# Returns an empty array [] if no qualifying items exist.

set -euo pipefail

# Fetch all items and filter to active statuses.
active_items=$(gh project item-list 170 \
  --owner PostHog \
  --format json \
  --limit 200 \
  | jq '[.items[] | select(.status == "In Progress" or .status == "Todo")]')

item_count=$(echo "$active_items" | jq 'length')

if [[ "$item_count" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# Separate linkable items (Issues/PRs with a content URL) from drafts.
linkable=$(echo "$active_items" | jq '[
  .[] | select(.content.url != null and .content.url != "") |
  {
    id: .id,
    title: .title,
    status: .status,
    url: .content.url,
    type: .content.type,
    number: (.content.number | tonumber),
    repo: .content.repository
  }
]')

drafts=$(echo "$active_items" | jq '[
  .[] | select(.content.url == null or .content.url == "") |
  {
    id: .id,
    title: .title,
    status: .status,
    url: null,
    type: null,
    number: null,
    assignees: []
  }
]')

linkable_count=$(echo "$linkable" | jq 'length')

if [[ "$linkable_count" -eq 0 ]]; then
  echo "$drafts"
  exit 0
fi

# Build a single GraphQL query to fetch assignees for all linkable items.
query=$(echo "$linkable" | jq -r '
  [to_entries[] |
    .key as $idx |
    .value as $item |
    ($item.repo | split("/")) as $parts |
    "item_\($idx): repository(owner: \"\($parts[0])\", name: \"\($parts[1])\") { " +
    if $item.type == "PullRequest" then
      "pullRequest(number: \($item.number)) { assignees(first: 10) { nodes { login } } }"
    else
      "issue(number: \($item.number)) { assignees(first: 10) { nodes { login } } }"
    end + " }"
  ] | "query { " + join(" ") + " }"
')

response=$(gh api graphql -f query="$query" 2>/dev/null) || response=""

# Join assignee data with linkable items. If the GraphQL call failed,
# fall back to empty assignees so the caller still gets usable output.
if [[ -n "$response" ]]; then
  enriched=$(echo "$linkable" | jq --argjson resp "$response" '
    [to_entries[] |
      .key as $idx |
      .value as $item |
      $resp.data["item_\($idx)"] as $data |
      (
        if $item.type == "PullRequest" then
          ($data.pullRequest.assignees.nodes // [])
        else
          ($data.issue.assignees.nodes // [])
        end
      ) as $nodes |
      {
        id: $item.id,
        title: $item.title,
        status: $item.status,
        url: $item.url,
        type: $item.type,
        number: $item.number,
        assignees: [$nodes[].login]
      }
    ]
  ')
else
  enriched=$(echo "$linkable" | jq '[.[] | . + {assignees: []} | del(.repo)]')
fi

# Merge linkable and draft items into a single array.
echo "$enriched" | jq --argjson drafts "$drafts" '. + $drafts'
