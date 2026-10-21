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
# Output: JSON array of merged PRs with title, url, closedAt, and repository
#   fields, most recently merged first.
#
# A PR counts as the user's when the user authored it, or when a cloud agent
# authored it as posthog[bot] and assigned it to the user. The agent assigns
# its PR to the person who started it. The PR names that person nowhere else
# that a search can match.
#
# Exits non-zero with a message on stderr when either search fills its limit.
# A full search may be missing PRs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"
SEARCH_PRS="$SCRIPT_DIR/search-prs.sh"

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

search() {
  "$SEARCH_PRS" "$@" \
    --owner="$SPRINT_ORG" \
    --merged \
    --merged-at="${start_date}..${end_date}" \
    --json title,url,closedAt,repository
}

authored=$(search --author="$username")
agent=$(search --author="$SPRINT_AGENT_AUTHOR" --assignee="$username")

printf '%s\n' "$authored" "$agent" | jq -s 'add | sort_by(.closedAt) | reverse'
