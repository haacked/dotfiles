#!/bin/bash
# Fetch project board items with assignee information. Uses a single batched
# GraphQL query (via batch-item-query.sh) to resolve assignees for all linkable
# items (Issues and PRs), keeping API calls to a minimum.
#
# Usage: fetch-board-goals.sh [--all]
#
#   --all  Return every item regardless of status. Without this flag only
#          In Progress and Todo items are returned.
#
# Output: JSON array of items with fields:
#   id, title, status, url, type, number, assignees
#
# Draft items (no linked Issue/PR) have null url, type, number,
# and an empty assignees array.
#
# Returns an empty array [] if no qualifying items exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
BATCH_QUERY="$SCRIPT_DIR/batch-item-query.sh"

all_statuses=false
if [[ "${1:-}" == "--all" ]]; then
  all_statuses=true
fi

# Fetch all items, optionally filtering to active statuses.
raw_items=$(gh project item-list "$SPRINT_PROJECT_NUMBER" \
  --owner "$SPRINT_ORG" \
  --format json \
  --limit 200 \
  | jq '.items')

if [[ "$all_statuses" == "false" ]]; then
  active_items=$(echo "$raw_items" | jq '[.[] | select(.status == "In Progress" or .status == "Todo")]')
else
  active_items=$(echo "$raw_items" | jq '[.[]]')
fi

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

# Resolve assignees for every linkable item in one batched query. The helper
# preserves input order, so item_<idx> lines up with linkable below.
assignee_fields="assignees(first: 10) { nodes { login } }"
response=$(echo "$linkable" \
  | jq '[.[] | {owner: (.repo | split("/")[0]), repo: (.repo | split("/")[1]), type: .type, number: .number}]' \
  | "$BATCH_QUERY" "$assignee_fields" "$assignee_fields")

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
