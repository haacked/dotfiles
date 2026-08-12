#!/usr/bin/env bash
# record-dismissed-comment.sh - Record a dismissed review comment in the shared state file
#
# Usage: record-dismissed-comment.sh <repo> <pr_number> < comment-body
#
# Reads the comment body from stdin (bodies contain quotes and newlines), hashes
# it with the same normalization as the review loop, and appends
# {"body_hash", "body_preview"} to the dismissed_comments array in:
#   ~/.local/state/copilot-review-loop/{owner}-{repo_name}-{pr_number}.json
#
# Creates the state file if it doesn't exist. Idempotent: a body whose hash is
# already recorded — in either the object or legacy bare-string shape — is a
# no-op.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
# shellcheck source=bin/lib/copilot.sh
source "${DOTFILES_DIR}/bin/lib/copilot.sh"
# shellcheck source=bin/lib/fs.sh
source "${DOTFILES_DIR}/bin/lib/fs.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number> < comment-body" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"

STATE_FILE=$(dismissed_state_file "$REPO" "$PR_NUMBER")

body=$(cat)
if [[ -z "${body//[[:space:]]/}" ]]; then
  echo "Error: empty comment body on stdin" >&2
  exit 1
fi

state=$(read_state_file "$STATE_FILE")

body_hash=$(hash_comment "$body")

if echo "$state" | jq -e --arg h "$body_hash" \
  '[ '"$DISMISSED_OBJECTS_JQ"' | select(.body_hash == $h) ] | length > 0' >/dev/null; then
  echo "Already recorded: ${body_hash}"
  exit 0
fi

body_preview=$(echo "$body" | head -c 80)
state=$(echo "$state" | jq \
  --arg h "$body_hash" \
  --arg p "$body_preview" \
  '.dismissed_comments += [{"body_hash": $h, "body_preview": $p}]')

mkdir -p "$(dirname "$STATE_FILE")"
echo "$state" | atomic_write "$STATE_FILE"
echo "Recorded: ${body_hash}"
