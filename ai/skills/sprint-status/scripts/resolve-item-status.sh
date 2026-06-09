#!/bin/bash
# Resolve the current state of the GitHub issues/PRs referenced in a sprint
# plan. Reads issue/PR URLs on stdin (one per line, extra text ignored) and
# returns a JSON array describing each item, using a single batched GraphQL
# query to keep API calls to a minimum.
#
# Usage:
#   echo "https://github.com/PostHog/posthog/pull/60569" | resolve-item-status.sh
#   resolve-item-status.sh < urls.txt
#
# Output: JSON array of objects, one per unique URL:
#   {
#     url, owner, repo,
#     type        ("PullRequest" | "Issue"),
#     number,
#     state       ("OPEN" | "CLOSED" | "MERGED"),
#     isDraft     (bool, PRs only; null for issues),
#     stateReason ("COMPLETED" | "NOT_PLANNED" | null; issues only),
#     title
#   }
#
# URLs that can't be parsed are skipped. Returns [] for empty input. If the
# GraphQL call fails entirely, state/isDraft/stateReason/title come back null
# so the caller still has the URLs.

set -euo pipefail

input="$(cat)"

refs=$(printf '%s\n' "$input" \
  | { grep -oE 'github\.com/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+/(pull|issues)/[0-9]+' || true; } \
  | sort -u \
  | jq -R -s '
      split("\n") | map(select(length > 0)) | map(
        split("/") as $p | {
          url: ("https://" + .),
          owner: $p[1],
          repo: $p[2],
          type: (if $p[3] == "pull" then "PullRequest" else "Issue" end),
          number: ($p[4] | tonumber)
        }
      )
    ')

count=$(echo "$refs" | jq 'length')
if [[ "$count" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# Build a single GraphQL query with one aliased field per item.
query=$(echo "$refs" | jq -r '
  [to_entries[] |
    .key as $i | .value as $it |
    "item_\($i): repository(owner: \($it.owner | @json), name: \($it.repo | @json)) { " +
    (if $it.type == "PullRequest" then
       "pullRequest(number: \($it.number)) { state isDraft title }"
     else
       "issue(number: \($it.number)) { state stateReason title }"
     end) + " }"
  ] | "query { " + join(" ") + " }"
')

response=$(gh api graphql -f query="$query" 2>/dev/null) || true

# A batch where one ref fails (e.g. an /issues/N link that is really a PR)
# still returns every resolved item under .data alongside an .errors array,
# but gh exits non-zero. Keep that partial data; only fall back to all-null
# when there is no .data at all. The per-item merge below null-propagates
# individually unresolved aliases.
if ! jq -e '.data' <<<"$response" >/dev/null 2>&1; then
  response=""
fi

if [[ -z "$response" ]]; then
  # API failed entirely; return refs with null state so the caller still
  # has URLs and can degrade gracefully.
  echo "$refs" | jq '[.[] | . + {state: null, isDraft: null, stateReason: null, title: null}]'
  exit 0
fi

echo "$refs" | jq --argjson resp "$response" '
  [to_entries[] |
    .key as $i | .value as $it |
    $resp.data["item_\($i)"] as $d |
    (if $it.type == "PullRequest" then $d.pullRequest else $d.issue end) as $node |
    $it + {
      state: $node.state,
      isDraft: $node.isDraft,
      stateReason: $node.stateReason,
      title: $node.title
    }
  ]
'
