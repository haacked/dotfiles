#!/bin/bash
# Run `gh search prs` and refuse a result that may have been cut off.
#
# Usage: search-prs.sh <gh search prs arguments, without --limit>
#
# Output: the JSON array gh prints.
#
# gh's search returns no total count, so a read that fills --limit is the only
# sign that matches were dropped. Such a read exits non-zero with a message on
# stderr, because a truncated list reads to every caller as work that isn't
# there.
#
# Environment:
#   PR_SEARCH_LIMIT - --limit passed to gh (default 1000, the most results
#                     GitHub's search API returns for one query).

set -euo pipefail

limit="${PR_SEARCH_LIMIT:-1000}"

response=$(gh search prs "$@" --limit "$limit")
count=$(jq length <<<"$response")

if ((count >= limit)); then
  echo "Error: gh search prs $* returned $count results at --limit $limit." >&2
  echo "Refusing to continue with a search that may be truncated." >&2
  exit 1
fi

echo "$response"
