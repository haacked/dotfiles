#!/bin/bash
# Fetch project board items with assignee information. The board listing already
# carries each item's assignees, so one call answers the whole question.
#
# Usage: fetch-board-goals.sh [--all]
#
#   --all  Return every item regardless of status. Without this flag only
#          In Progress and Todo items are returned.
#
# Output: JSON array of items with fields:
#   id, title, status, url, type, number, assignees
#
# Draft items (no linked Issue/PR) have null url, type and number.
#
# Returns an empty array [] if no qualifying items exist.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BOARD_ITEMS="$SCRIPT_DIR/fetch-board-items.sh"

all_statuses=false
if [[ "${1:-}" == "--all" ]]; then
  all_statuses=true
fi

# Fetch all items, optionally filtering to active statuses.
raw_items=$("$BOARD_ITEMS")

if [[ "$all_statuses" == "false" ]]; then
  active_items=$(echo "$raw_items" | jq '[.[] | select(.status == "In Progress" or .status == "Todo" or .status == "In Review" or .status == "Approved")]')
else
  active_items=$(echo "$raw_items" | jq '[.[]]')
fi

# A draft has no linked Issue or PR, so its url, type and number stay null.
echo "$active_items" | jq '[
  .[] |
  (if (.content.url // "") == "" then null else .content end) as $content |
  {
    id: .id,
    title: .title,
    status: .status,
    url: $content.url,
    type: $content.type,
    number: (if $content == null then null else ($content.number | tonumber) end),
    assignees: (.assignees // [])
  }
]'
