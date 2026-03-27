#!/usr/bin/env bash
# github.sh - Shared GitHub helpers
#
# Source this file to get GitHub helpers:
#   source "${SCRIPT_DIR}/lib/github.sh"
#
# Functions:
#   parse_pr_url      - Parse a GitHub PR URL into OWNER, REPO_NAME, REPO, PR_NUMBER
#   get_current_repo  - Get the current repo as owner/name
#   resolve_pr_target - Resolve a PR argument (URL, number, or branch) into OWNER, REPO_NAME, REPO, PR_NUMBER

# Parse a GitHub PR URL into OWNER, REPO_NAME, REPO, and PR_NUMBER.
# Returns 0 on success, 1 if the string is not a valid PR URL.
# shellcheck disable=SC2034  # Variables are intentionally set for the caller
parse_pr_url() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
    OWNER="${BASH_REMATCH[1]}"
    REPO_NAME="${BASH_REMATCH[2]}"
    REPO="${OWNER}/${REPO_NAME}"
    PR_NUMBER="${BASH_REMATCH[3]}"
    return 0
  fi
  return 1
}

# Get the current repository as owner/name.
# shellcheck disable=SC2034  # Variables are intentionally set for the caller
get_current_repo() {
  gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || {
    log_error "Could not determine repository. Run from inside a repo or pass a full PR URL."
    exit 1
  }
}

# Resolve a PR argument into OWNER, REPO_NAME, REPO, and PR_NUMBER.
# Accepts a URL, numeric PR number, or empty string (infers from current branch).
# Returns 0 on success, exits on failure.
# shellcheck disable=SC2034  # Variables are intentionally set for the caller
resolve_pr_target() {
  local pr_arg="${1:-}"
  if [[ -z "$pr_arg" ]]; then
    local pr_json
    pr_json=$(gh pr view --json number 2>/dev/null) || {
      log_error "No PR found for the current branch. Specify a PR number or URL."
      exit 1
    }
    PR_NUMBER=$(echo "$pr_json" | jq -r '.number')
    REPO=$(get_current_repo)
  elif parse_pr_url "$pr_arg"; then
    :
  elif [[ "$pr_arg" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="$pr_arg"
    REPO=$(get_current_repo)
  else
    log_error "Invalid PR argument: ${pr_arg}"
    log_error "Expected a PR number or URL."
    exit 1
  fi
  if [[ -z "${OWNER:-}" ]]; then
    OWNER="${REPO%%/*}"
    REPO_NAME="${REPO##*/}"
  fi
}
