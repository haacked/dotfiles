#!/bin/bash
# List project board items in the "Done" column that were closed or merged
# before the current sprint started. These are candidates for archiving to
# keep the board tidy between sprints.
#
# Usage: archive-done-items.sh <sprint_start_date>
#
# Arguments:
#   sprint_start_date - Current sprint's start date (YYYY-MM-DD). Items
#                       closed/merged before this date are included.
#
# Output: JSON array of qualifying items with fields:
#   id, title, number, type, closed_date
#
# Returns an empty array [] if no items qualify.

set -euo pipefail

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <sprint_start_date>" >&2
  exit 1
fi

sprint_start="$1"

if ! [[ "$sprint_start" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
  echo "Error: sprint_start_date must be YYYY-MM-DD, got: $sprint_start" >&2
  exit 1
fi

# Fetch all Done items from the project board as JSON.
done_items=$(gh project item-list 170 \
  --owner PostHog \
  --format json \
  --limit 200 \
  | jq '[.items[] | select(.status == "Done")]')

# Extract non-draft items (those with a content URL) into a compact working set.
work_items=$(echo "$done_items" | jq '[
  .[] | select(.content.url != null and .content.url != "") |
  {
    id: .id,
    title: .title,
    type: .content.type,
    number: (.content.number | tonumber),
    repo: .content.repository
  }
]')

item_count=$(echo "$work_items" | jq 'length')

if [[ "$item_count" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# Build a single GraphQL query to fetch closed/merged dates for all items,
# replacing N sequential REST API calls with one batched request.
query=$(echo "$work_items" | jq -r '
  [to_entries[] |
    .key as $idx |
    .value as $item |
    ($item.repo | split("/")) as $parts |
    "item_\($idx): repository(owner: \"\($parts[0])\", name: \"\($parts[1])\") { " +
    if $item.type == "PullRequest" then
      "pullRequest(number: \($item.number)) { mergedAt closedAt }"
    else
      "issue(number: \($item.number)) { closedAt }"
    end + " }"
  ] | "query { " + join(" ") + " }"
')

response=$(gh api graphql -f query="$query" 2>/dev/null) || response=""

if [[ -z "$response" ]]; then
  echo "[]"
  exit 0
fi

# Join the batched results with work items and filter to those closed before
# the sprint start date.
echo "$work_items" | jq --arg sprint "$sprint_start" --argjson resp "$response" '
  [to_entries[] |
    .key as $idx |
    .value as $item |
    $resp.data["item_\($idx)"] as $data |
    (
      if $item.type == "PullRequest" then
        ($data.pullRequest.mergedAt // $data.pullRequest.closedAt // null)
      else
        ($data.issue.closedAt // null)
      end
    ) as $closed |
    select($closed != null) |
    ($closed | .[0:10]) as $day |
    select($day < $sprint) |
    {id: $item.id, title: $item.title, number: $item.number, type: $item.type, closed_date: $day}
  ]
'
