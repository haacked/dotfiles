#!/bin/bash
# Fetch the Feature Flags Platform team's sprint planning comment from a given
# sprint issue.
#
# Searches issue comments for one containing "# Team Feature Flags Platform"
# or "# Team Feature Flags" (the team has used both headings historically).
# Returns the comment body, or "NOT_FOUND" if no matching comment exists.
#
# Usage: fetch-previous-comment.sh <issue_number>
#
# Output: The full comment body text, or the literal string "NOT_FOUND".

set -euo pipefail

if [ $# -lt 1 ]; then
  echo "Usage: $0 <issue_number>" >&2
  exit 1
fi

issue_number="$1"

# Fetch all comments and find ours. We check for both possible team headings
# since the team name has varied across sprints.
comment=$(gh api "repos/PostHog/posthog/issues/${issue_number}/comments" \
  --paginate \
  --jq '.[] | select(.body | test("# Team Feature Flags Platform|# Team Feature Flags[^/]")) | .body' \
  2>/dev/null | head -1)

if [ -z "$comment" ]; then
  echo "NOT_FOUND"
else
  echo "$comment"
fi
