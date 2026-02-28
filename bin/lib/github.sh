#!/usr/bin/env bash
# github.sh - Shared GitHub URL parsing utilities
#
# Source this file to get URL parsing helpers:
#   source "${SCRIPT_DIR}/lib/github.sh"
#
# Functions:
#   parse_pr_url - Parse a GitHub PR URL into OWNER, REPO_NAME, REPO, PR_NUMBER

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
