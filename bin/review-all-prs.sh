#!/usr/bin/env bash
# review-all-prs.sh - Find PRs awaiting your review in a GitHub organization
#
# Uses GitHub GraphQL API to efficiently find all open PRs where you are
# a requested reviewer, filtering out PRs you've already reviewed.
#
# Usage:
#   review-all-prs.sh [OPTIONS]
#
# Options:
#   --org ORG       GitHub organization (default: PostHog)
#   --limit N       Maximum number of PRs to return (default: 50)
#   --json          Output raw JSON (default: formatted table)
#   --include-reviewed  Include PRs you've already reviewed
#   -h, --help      Show this help message
#
# Output (JSON mode):
#   [
#     {
#       "number": 123,
#       "title": "PR title",
#       "url": "https://github.com/org/repo/pull/123",
#       "repo": "org/repo",
#       "author": "username",
#       "updated_at": "2024-01-15T10:30:00Z",
#       "user_review_state": null
#     }
#   ]

set -euo pipefail

# Defaults
ORG="PostHog"
LIMIT=50
JSON_OUTPUT=false
INCLUDE_REVIEWED=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Find PRs awaiting your review in a GitHub organization.

Options:
  --org ORG           GitHub organization (default: PostHog)
  --limit N           Maximum number of PRs to return (default: 50)
  --json              Output raw JSON (default: formatted table)
  --include-reviewed  Include PRs you've already reviewed
  -h, --help          Show this help message

Examples:
  $(basename "$0")                    # Find PRs in PostHog org
  $(basename "$0") --org myorg        # Find PRs in myorg
  $(basename "$0") --json             # Output as JSON for scripting
  $(basename "$0") --limit 10         # Limit to 10 PRs
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --org)
      ORG="$2"
      shift 2
      ;;
    --limit)
      LIMIT="$2"
      shift 2
      ;;
    --json)
      JSON_OUTPUT=true
      shift
      ;;
    --include-reviewed)
      INCLUDE_REVIEWED=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# Get current GitHub username
GITHUB_USER=$(gh api user --jq '.login')
if [[ -z "$GITHUB_USER" ]]; then
  echo "Error: Could not determine GitHub username. Are you logged in with 'gh auth login'?" >&2
  exit 1
fi

# GraphQL query to find PRs where user is requested reviewer
# Includes review state to filter out already-reviewed PRs
# shellcheck disable=SC2016 # GraphQL variables use $ syntax, not shell expansion
QUERY='
query($searchQuery: String!, $limit: Int!) {
  search(query: $searchQuery, type: ISSUE, first: $limit) {
    edges {
      node {
        ... on PullRequest {
          number
          title
          url
          repository {
            nameWithOwner
          }
          author {
            login
          }
          updatedAt
          reviews(last: 50) {
            nodes {
              author {
                login
              }
              state
            }
          }
        }
      }
    }
  }
}
'

SEARCH_QUERY="is:pr is:open review-requested:@me org:${ORG}"

# Execute GraphQL query
RESULT=$(gh api graphql \
  -f query="$QUERY" \
  -F searchQuery="$SEARCH_QUERY" \
  -F limit="$LIMIT" \
  2>&1) || {
  echo "Error: GraphQL query failed: $RESULT" >&2
  exit 1
}

# Process results with jq
# - Extract PR data
# - Check if user has already reviewed
# - Filter based on --include-reviewed flag
PROCESSED=$(echo "$RESULT" | jq --arg user "$GITHUB_USER" --argjson include_reviewed "$INCLUDE_REVIEWED" '
  .data.search.edges
  | map(.node)
  | map(select(. != null))
  | map({
      number: .number,
      title: .title,
      url: .url,
      repo: .repository.nameWithOwner,
      author: .author.login,
      updated_at: .updatedAt,
      user_review_state: (
        .reviews.nodes
        | map(select(.author.login == $user))
        | map(.state)
        | if length > 0 then .[0] else null end
      )
    })
  | if $include_reviewed then . else map(select(.user_review_state == null)) end
  | sort_by(.updated_at)
  | reverse
')

# Count results
COUNT=$(echo "$PROCESSED" | jq 'length')

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "$PROCESSED"
else
  if [[ "$COUNT" -eq 0 ]]; then
    echo "No PRs awaiting your review in ${ORG}."
    exit 0
  fi

  echo "Found $COUNT PR(s) awaiting review in ${ORG}:"
  echo ""

  # Print formatted table
  printf "%-6s %-25s %-50s %s\n" "PR#" "REPO" "TITLE" "AUTHOR"
  printf "%s\n" "$(printf '%.0s-' {1..120})"

  echo "$PROCESSED" | jq -r '.[] | [
    .number,
    (.repo | split("/")[1] | .[0:25]),
    (.title | .[0:50]),
    .author
  ] | @tsv' | while IFS=$'\t' read -r num repo title author; do
    printf "%-6s %-25s %-50s %s\n" "$num" "$repo" "$title" "$author"
  done

  echo ""
  echo "Run with --json for machine-readable output."
fi
