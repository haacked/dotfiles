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

item_count=$(echo "$done_items" | jq 'length')

if [[ "$item_count" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

results="[]"

for i in $(seq 0 $((item_count - 1))); do
  item=$(echo "$done_items" | jq ".[$i]")

  # Draft items have no content — skip them.
  content_url=$(echo "$item" | jq -r '.content.url // empty')
  if [[ -z "$content_url" ]]; then
    continue
  fi

  item_id=$(echo "$item" | jq -r '.id')
  title=$(echo "$item" | jq -r '.title')
  content_type=$(echo "$item" | jq -r '.content.type')
  content_number=$(echo "$item" | jq -r '.content.number')
  repo=$(echo "$item" | jq -r '.content.repository')

  # Determine the closed/merged date via the GitHub API.
  closed_date=""
  if [[ "$content_type" == "PullRequest" ]]; then
    pr_data=$(gh api "repos/${repo}/pulls/${content_number}" --jq '{merged_at, closed_at}' 2>/dev/null) || pr_data=""
    if [[ -n "$pr_data" ]]; then
      closed_date=$(echo "$pr_data" | jq -r '.merged_at // .closed_at // empty')
    fi
  elif [[ "$content_type" == "Issue" ]]; then
    closed_date=$(gh api "repos/${repo}/issues/${content_number}" --jq '.closed_at // empty' 2>/dev/null) || closed_date=""
  fi

  if [[ -z "$closed_date" ]]; then
    continue
  fi

  # Compare only the date portion (YYYY-MM-DD) against the sprint start.
  closed_day="${closed_date:0:10}"
  if [[ "$closed_day" < "$sprint_start" ]]; then
    results=$(echo "$results" | jq \
      --arg id "$item_id" \
      --arg title "$title" \
      --arg number "$content_number" \
      --arg type "$content_type" \
      --arg closed_date "$closed_day" \
      '. + [{"id": $id, "title": $title, "number": ($number | tonumber), "type": $type, "closed_date": $closed_date}]')
  fi
done

echo "$results" | jq '.'
