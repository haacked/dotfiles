#!/usr/bin/env bash
# fetch-unaddressed-comments.sh - Fetch unresolved review comments, minus dismissed ones
#
# Usage: fetch-unaddressed-comments.sh <repo> <pr_number>
#
# Output: JSON array of unresolved inline review comments from any reviewer
# (Copilot, humans, other bots) that have NOT been previously dismissed.
# Each comment has: {id, path, line, body, diff_hunk, author, is_bot}
#
# Reads dismissed-comment hashes from the shared state file at:
#   ~/.local/state/copilot-review-loop/{owner}-{repo_name}-{pr_number}.json

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
source "${DOTFILES_DIR}/bin/lib/copilot.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number>" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"

STATE_FILE=$(dismissed_state_file "$REPO" "$PR_NUMBER")

# Fetch all unresolved review comments across every reviewer
comments=$(fetch_unresolved_review_comments)
comment_count=$(echo "$comments" | jq 'length')

if [[ "$comment_count" -eq 0 ]]; then
  echo "[]"
  exit 0
fi

# Load dismissed hashes from the state file, normalizing both entry shapes:
# objects from the review loop and bare hash strings from older skill runs.
# read_state_file fails loud on a corrupt file, ending the run via errexit.
state=$(read_state_file "$STATE_FILE")
dismissed_hashes=$(echo "$state" | jq -r "$DISMISSED_OBJECTS_JQ"' | .body_hash')

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
