#!/usr/bin/env bash
# filter-dismissed-comments.sh - Fetch review comments and filter out dismissed ones
#
# Usage: filter-dismissed-comments.sh <repo> <pr_number> <review_id>
#
# Output: JSON array of comments that have NOT been previously dismissed.
# Each comment has: {id, path, line, body, diff_hunk}
#
# Reads dismissed-comment hashes from the shared state file at:
#   ~/.local/state/copilot-review-loop/{owner}-{repo_name}-{pr_number}.json

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
source "${DOTFILES_DIR}/bin/lib/copilot.sh"

if [[ $# -lt 3 ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number> <review_id>" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"
review_id="$3"

# Derive owner and repo_name from REPO for state file path
owner="${REPO%%/*}"
repo_name="${REPO##*/}"

STATE_DIR="${HOME}/.local/state/copilot-review-loop"
STATE_FILE="${STATE_DIR}/${owner}-${repo_name}-${PR_NUMBER}.json"

# Fetch all comments for this review
comments=$(fetch_review_comments "$review_id")
comment_count=$(echo "$comments" | jq 'length')

if [[ "$comment_count" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# Load dismissed hashes from state file
if [[ -f "$STATE_FILE" ]]; then
  dismissed_hashes=$(jq -r '.dismissed_comments[].body_hash' < "$STATE_FILE")
else
  dismissed_hashes=""
fi

# Build a lookup set from dismissed hashes
declare -A dismissed_set
while IFS= read -r h; do
  [[ -n "$h" ]] && dismissed_set["$h"]=1
done <<< "$dismissed_hashes"

# Filter comments, collecting non-dismissed ones as ndjson
tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

while IFS= read -r comment; do
  body=$(echo "$comment" | jq -r '.body')
  body_hash=$(hash_comment "$body")
  if [[ -z "${dismissed_set[$body_hash]+isset}" ]]; then
    echo "$comment" >> "$tmpfile"
  fi
done < <(echo "$comments" | jq -c '.[]')

if [[ -s "$tmpfile" ]]; then
  jq -s '.' < "$tmpfile"
else
  echo "[]"
fi
