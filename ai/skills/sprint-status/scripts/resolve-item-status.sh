#!/bin/bash
# Resolve the current state of the GitHub issues/PRs referenced in a sprint
# plan. Reads issue/PR URLs on stdin (one per line, extra text ignored) and
# returns a JSON array describing each item. The batched GraphQL lookup is
# delegated to sprint-planning's shared batch-item-query.sh.
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BATCH_QUERY="$SCRIPT_DIR/../../sprint-planning/scripts/batch-item-query.sh"

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

response=$(echo "$refs" | "$BATCH_QUERY" "state isDraft title" "state stateReason title")

if [[ -z "$response" ]]; then
  # Query failed entirely; return refs with null state so the caller still
  # has URLs and can degrade gracefully.
  echo "$refs" | jq '[.[] | . + {state: null, isDraft: null, stateReason: null, title: null}]'
  exit 0
fi

# Join the batched results back onto the refs by index. A ref that failed
# individually (e.g. an /issues/N link that is really a PR) has a null node,
# and jq null-propagates each field for it while the rest stay accurate.
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
