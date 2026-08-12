#!/bin/bash
# Fetch every item on the team's project board.
#
# Usage: fetch-board-items.sh
#
# Output: JSON array of project items, exactly as the .items of
#   `gh project item-list --format json`.
#
# gh's --limit is a ceiling rather than a fetch count: it pages internally and
# stops when the board runs out, so asking for more than the board holds costs
# nothing. The limit is set high enough that a real board never reaches it.
#
# A short read is detectable from .totalCount when gh reports it, and otherwise
# from a read that exactly fills the limit. A short read exits non-zero with a
# message on stderr, because a truncated board reads to every caller as work
# that isn't there.
#
# Environment:
#   BOARD_FETCH_LIMIT - --limit passed to gh (default 100000). Lower it to
#                       exercise the truncation guard against a real board.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/config.sh"

limit="${BOARD_FETCH_LIMIT:-100000}"

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
  echo "Error: fetched $(jq '.items | length' <<<"$response") of $(jq -r '.totalCount // "unknown"' <<<"$response") items from project $SPRINT_PROJECT_NUMBER at --limit $limit." >&2
  echo "Refusing to continue with a truncated board." >&2
  exit 1
fi

jq '.items' <<<"$response"
