#!/bin/bash
# Fetch the configured team's sprint planning comment from a given sprint issue.
#
# Searches issue comments for one whose body contains a line matching
# SPRINT_COMMENT_HEADER (see config.sh). Returns the comment body, or
# "NOT_FOUND" if no matching comment exists.
#
# Usage: fetch-previous-comment.sh [--sections] <issue_number>
#
#   --sections  Extract only the ## Quarter goals and ## Plan sections
#               instead of returning the full comment. Useful when only
#               planning context is needed and the full comment would add
#               unnecessary tokens to context.
#
# Output: The comment body text (or extracted sections), or "NOT_FOUND".

set -euo pipefail

source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.sh"

sections_only=false
if [[ "${1:-}" == "--sections" ]]; then
  sections_only=true
  shift
fi

if [[ $# -lt 1 ]]; then
  echo "Usage: $0 [--sections] <issue_number>" >&2
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
elif [[ "$sections_only" == "true" ]]; then
  # Extract ## Quarter goals and ## Plan sections (everything from each
  # heading up to the next same-level (##) heading or end of comment).
  sections=$(echo "$comment" | awk '
    /^## (Quarter goals|Plan)/ { printing=1 }
    printing && /^## / && !/^## (Quarter goals|Plan)/ { printing=0 }
    printing { print }
  ')
  if [[ -n "$sections" ]]; then
    echo "$sections"
  else
    # The comment lacks the expected headings (older format or edited
    # comment); return the full body so callers still get usable content.
    echo "$comment"
  fi
else
  echo "$comment"
fi
