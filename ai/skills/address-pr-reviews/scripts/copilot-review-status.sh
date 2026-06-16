#!/usr/bin/env bash
# copilot-review-status.sh - Check the status of the latest Copilot review
#
# Usage: copilot-review-status.sh <repo> <pr_number>
#
# Output: JSON object with fields:
#   review_id      - Copilot review ID (0 if none)
#   review_commit  - Commit SHA the review covers ("" if none)
#   head_sha       - Current HEAD SHA of the PR
#   comment_count  - Number of inline comments (0 if no review)
#   status         - One of: "none", "pending", "stale", "current"
#
# Status meanings:
#   none    - No Copilot review exists and none is pending
#   pending - A review has been requested but not yet submitted
#   stale   - A review exists but covers an older commit
#   current - A review exists and covers the current HEAD

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
source "${DOTFILES_DIR}/bin/lib/logging.sh"
source "${DOTFILES_DIR}/bin/lib/copilot.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number>" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"

head_sha=$(get_pr_head_sha) || {
  echo "Error: could not fetch HEAD SHA for ${REPO}#${PR_NUMBER}" >&2
  exit 1
}

latest_review=$(get_latest_copilot_review 2>/dev/null || echo "null")
review_id=$(echo "$latest_review" | jq -r '.id // 0')
review_commit=$(echo "$latest_review" | jq -r '.commit_id // ""')

# Determine status
if [[ "$review_id" == "0" || "$review_id" == "null" ]]; then
  review_id=0
  review_commit=""
  if is_copilot_review_pending; then
    status="pending"
  else
    status="none"
  fi
  comment_count=0
else
  comment_count=$(fetch_review_comments "$review_id" | jq 'length')
  if [[ "$review_commit" == "$head_sha" ]]; then
    status="current"
  elif is_copilot_review_pending; then
    status="pending"
  else
    status="stale"
  fi
fi

jq -n \
  --argjson review_id "$review_id" \
  --arg review_commit "$review_commit" \
  --arg head_sha "$head_sha" \
  --argjson comment_count "$comment_count" \
  --arg status "$status" \
  '{review_id: $review_id, review_commit: $review_commit, head_sha: $head_sha, comment_count: $comment_count, status: $status}'
