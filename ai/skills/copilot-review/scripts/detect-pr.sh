#!/usr/bin/env bash
# detect-pr.sh - Detect PR from a URL, number, or current branch
#
# Usage: detect-pr.sh [<pr-url>|<pr-number>|""]
#
# Output (tab-separated):
#   <owner>\t<repo_name>\t<repo>\t<pr_number>
#
# Exit codes:
#   0 - Success
#   1 - Could not detect PR

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
source "${DOTFILES_DIR}/bin/lib/github.sh"

input="${1:-}"

if [[ -z "$input" ]]; then
  # No argument: detect from current branch
  pr_json=$(gh pr view --json number,url -q '{number: .number, url: .url}' 2>/dev/null) || {
    echo "Error: no PR associated with the current branch. Provide a PR URL or number." >&2
    exit 1
  }
  pr_url=$(echo "$pr_json" | jq -r '.url')
  if ! parse_pr_url "$pr_url"; then
    echo "Error: could not parse PR URL from current branch: ${pr_url}" >&2
    exit 1
  fi
elif [[ "$input" =~ ^https://github\.com/ ]]; then
  # Full URL
  if ! parse_pr_url "$input"; then
    echo "Error: invalid GitHub PR URL: ${input}" >&2
    echo "Expected format: https://github.com/owner/repo/pull/123" >&2
    exit 1
  fi
elif [[ "$input" =~ ^[0-9]+$ ]]; then
  # Bare PR number: infer repo from current directory
  repo_full=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
    echo "Error: could not determine repository. Run from inside a repo checkout." >&2
    exit 1
  }
  OWNER="${repo_full%%/*}"
  REPO_NAME="${repo_full##*/}"
  REPO="$repo_full"
  PR_NUMBER="$input"
else
  echo "Error: unrecognized argument: ${input}" >&2
  echo "Provide a PR URL (https://github.com/owner/repo/pull/123) or a PR number." >&2
  exit 1
fi

printf '%s\t%s\t%s\t%s\n' "$OWNER" "$REPO_NAME" "$REPO" "$PR_NUMBER"
