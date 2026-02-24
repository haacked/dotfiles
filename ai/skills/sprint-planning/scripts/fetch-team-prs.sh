#!/bin/bash
# Fetch merged PRs for a GitHub user within a date range across all PostHog
# repositories.
#
# Usage: fetch-team-prs.sh <username> <start_date> [end_date]
#
# Arguments:
#   username    - GitHub username (e.g., "haacked")
#   start_date  - Start of date range, inclusive (YYYY-MM-DD)
#   end_date    - End of date range, inclusive (YYYY-MM-DD, defaults to today)
#
# Output: JSON array of merged PRs with title, url, closedAt, and repository fields.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <username> <start_date> [end_date]" >&2
  exit 1
fi

username="$1"
start_date="$2"
end_date="${3:-$(date +%Y-%m-%d)}"

date_regex='^[0-9]{4}-[0-9]{2}-[0-9]{2}$'

if ! [[ "$start_date" =~ $date_regex ]]; then
  echo "Error: start_date must be YYYY-MM-DD, got: $start_date" >&2
  exit 1
fi

if ! [[ "$end_date" =~ $date_regex ]]; then
  echo "Error: end_date must be YYYY-MM-DD, got: $end_date" >&2
  exit 1
fi

gh search prs \
  --author="$username" \
  --owner=PostHog \
  --merged \
  --merged-at="${start_date}..${end_date}" \
  --limit=50 \
  --json title,url,closedAt,repository
