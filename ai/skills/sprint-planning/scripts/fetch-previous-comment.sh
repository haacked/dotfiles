#!/bin/bash
# Fetch the configured team's sprint planning comment from a given sprint issue.
#
# Searches issue comments for one whose body contains a line matching
# SPRINT_COMMENT_HEADER (see config.sh). Returns the comment body, or
# "NOT_FOUND" if no matching comment exists.
#
# Usage: fetch-previous-comment.sh <issue_number>
#
# Output: The full comment body text, or the literal string "NOT_FOUND".

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 <issue_number>" >&2
  exit 1
fi

issue_number="$1"

if ! [[ "$issue_number" =~ ^[0-9]+$ ]]; then
  echo "Error: issue_number must be numeric, got: $issue_number" >&2
  exit 1
fi

# Match the header as a whole line (trailing whitespace and CRLF stripped) so
# "# Team Feature Flags" does not collide with another team's
# "# Team Feature Flags Platform" heading.
comment=$(gh api "repos/${SPRINT_REPO}/issues/${issue_number}/comments?per_page=100" \
  --paginate \
  --jq '.[]' 2>/dev/null \
  | jq -s --arg hdr "$SPRINT_COMMENT_HEADER" \
      '[.[] | select(.body | split("\n") | map(sub("[ \t\r]+$"; "")) | index($hdr) != null)] | first | .body // empty') \
  || comment=""

if [[ -z "$comment" ]]; then
  echo "NOT_FOUND"
else
  echo "$comment"
fi
