#!/bin/bash
# Fetch every item on the team's project board.
#
# Usage: fetch-board-items.sh
#
# Output: JSON array of project items, exactly as the .items of
#   `gh project item-list --format json`.
#
# gh reports the board's real size in .totalCount, so a short read is
# detectable. A fetch that comes up short is retried sized to the board; one
# that is still short exits non-zero with a message on stderr, because a
# truncated board reads to every caller as work that isn't there.
#
# Environment:
#   SPRINT_BOARD_FETCH_LIMIT - starting --limit (default 1000). Lower it to
#                              exercise the retry path against a real board.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

limit="${SPRINT_BOARD_FETCH_LIMIT:-1000}"

fetch() {
  gh project item-list "$SPRINT_PROJECT_NUMBER" \
    --owner "$SPRINT_ORG" \
    --format json \
    --limit "$1"
}

# A read is short when gh returned fewer items than the board holds, or when it
# returned exactly the limit and reported no total to compare against.
is_short() {
  local response="$1" fetch_limit="$2"
  jq -e --argjson limit "$fetch_limit" '
    (.items | length) as $count |
    if (.totalCount | type) == "number" then $count < .totalCount
    else $count >= $limit
    end
  ' <<<"$response" >/dev/null
}

response=$(fetch "$limit")

if is_short "$response" "$limit"; then
  total=$(jq '.totalCount // 0' <<<"$response")
  # Size the retry to the board, with headroom for items added since.
  retry_limit=$(( (total > 2 * limit ? total : 2 * limit) + 100 ))
  response=$(fetch "$retry_limit")

  if is_short "$response" "$retry_limit"; then
    echo "Error: fetched $(jq '.items | length' <<<"$response") of $(jq -r '.totalCount // "unknown"' <<<"$response") items from project $SPRINT_PROJECT_NUMBER at --limit $retry_limit." >&2
    echo "Refusing to continue with a truncated board." >&2
    exit 1
  fi
fi

jq '.items' <<<"$response"
