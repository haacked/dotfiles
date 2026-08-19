#!/usr/bin/env bash
# github.sh - Shared GitHub helpers
#
# Source this file to get GitHub helpers:
#   source "${SCRIPT_DIR}/lib/github.sh"
#
# Functions:
#   get_github_user   - Print the authenticated GitHub username, or exit
#   parse_pr_url      - Parse a GitHub PR URL into OWNER, REPO_NAME, REPO, PR_NUMBER
#   get_current_repo  - Get the current repo as owner/name
#   resolve_pr_target - Resolve a PR argument (URL, number, or branch) into OWNER, REPO_NAME, REPO, PR_NUMBER
#   get_requested_reviewers - Requested reviewers on a PR as [{login, type}]

get_github_user() {
  gh api user --jq '.login' 2>/dev/null || {
    log_error "Could not determine GitHub username. Are you logged in with 'gh auth login'?"
    exit 1
  }
}

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
# Sets SKIP_REPO_VALIDATION=true when the repo is inferred from the working
# directory (bare number or auto-detect) to avoid a redundant gh call.
# Returns 0 on success, 1 on failure.
# shellcheck disable=SC2034  # Variables are intentionally set for the caller
SKIP_REPO_VALIDATION=false
resolve_pr_target() {
  local pr_arg="${1:-}"
  SKIP_REPO_VALIDATION=false
  if [[ -z "$pr_arg" ]]; then
    local pr_url
    pr_url=$(gh pr view --json url -q '.url' 2>/dev/null) || {
      log_error "No PR found for the current branch. Specify a PR number or URL."
      return 1
    }
    if ! parse_pr_url "$pr_url"; then
      log_error "Could not parse PR URL from current branch: ${pr_url}"
      return 1
    fi
    SKIP_REPO_VALIDATION=true
  elif parse_pr_url "$pr_arg"; then
    :
  elif [[ "$pr_arg" =~ ^[0-9]+$ ]]; then
    PR_NUMBER="$pr_arg"
    REPO=$(get_current_repo) || return 1
    OWNER="${REPO%%/*}"
    REPO_NAME="${REPO##*/}"
    SKIP_REPO_VALIDATION=true
  else
    log_error "Invalid PR argument: ${pr_arg}"
    log_error "Expected a PR number or URL (https://github.com/owner/repo/pull/123)."
    return 1
  fi
}

# Requested reviewers on a PR, as [{login, type}] where type is GraphQL's
# __typename ("User" or "Bot"). GitHub clears a request when that reviewer
# submits, so anything still listed is mid-review.
#
# GraphQL, not REST: `pulls/:n/requested_reviewers` returns only `.users`, and a
# GitHub App reviewer (Copilot, Greptile) is a Bot node that never appears there,
# so the REST list reads empty while the app is mid-review. Team and Mannequin
# nodes drop out here, which is what excludes teams: a team request lingers until
# a human member reviews, which a bot's review never satisfies.
#
# Usage: get_requested_reviewers <owner/repo> <pr_number>
get_requested_reviewers() {
  local slug="$1" pr="$2"

  # shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
  local query='query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr) {
          reviewRequests(first: 100) {
            nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } } }
          }
        }
      }
    }'

  gh api graphql \
    -f query="$query" \
    -f owner="${slug%%/*}" \
    -f name="${slug##*/}" \
    -F pr="$pr" \
    --jq '[.data.repository.pullRequest.reviewRequests.nodes[]?.requestedReviewer
           | select(. != null and (.__typename == "User" or .__typename == "Bot"))
           | {login: (.login // ""), type: .__typename}]'
}
