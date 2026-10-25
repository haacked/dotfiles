#!/bin/bash
# Run a GitHub issue search and print every PR it matches.
#
# Usage: standup-search.sh <search query>
#
# Output: one JSON object per line, with number, title, url, repo, author,
# draft, updated_at, and merged_at.
#
# A search that returns fewer items than its total_count, or that GitHub marks
# incomplete, exits non-zero with a message on stderr. The standup would
# otherwise leave the missing PRs out of the notes. GitHub returns at most 1,000
# results for one query, so a larger match also fails.
#
# This uses search/issues rather than `gh search prs`, because `gh search prs
# --merged` returns stale results for date filters.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: standup-search.sh <search query>" >&2
  exit 64
fi

query="$1"

pages=$(gh api search/issues --method GET --paginate --slurp -f per_page=100 -f q="$query")

total=$(jq '.[0].total_count' <<<"$pages")
count=$(jq '[.[].items[]] | length' <<<"$pages")
incomplete=$(jq 'any(.[]; .incomplete_results)' <<<"$pages")

if ((count < total)) || [[ "$incomplete" == true ]]; then
  echo "Error: the search returned $count of $total results (incomplete_results: $incomplete) for: $query" >&2
  echo "Refusing to continue with a search that may be truncated." >&2
  exit 1
fi

jq -c '.[].items[] | {
  number,
  title,
  url: .html_url,
  repo: (.repository_url | sub(".*/repos/"; "")),
  author: .user.login,
  draft,
  updated_at,
  merged_at: .pull_request.merged_at
}' <<<"$pages"
