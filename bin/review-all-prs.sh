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
#   --team TEAM     Also find PRs requested from this team (repeatable)
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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/github.sh"

# Defaults
ORG="PostHog"
LIMIT=50
JSON_OUTPUT=false
INCLUDE_REVIEWED=false
TEAMS=()

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Find PRs awaiting your review in a GitHub organization.

Options:
  --org ORG           GitHub organization (default: PostHog)
  --limit N           Maximum number of PRs to return (default: 50)
  --json              Output raw JSON (default: formatted table)
  --team TEAM         Also find PRs requested from this team (repeatable)
  --include-reviewed  Include PRs you've already reviewed
  -h, --help          Show this help message

Examples:
  $(basename "$0")                    # Find PRs in PostHog org
  $(basename "$0") --org myorg        # Find PRs in myorg
  $(basename "$0") --json             # Output as JSON for scripting
  $(basename "$0") --limit 10         # Limit to 10 PRs
  $(basename "$0") --team my-team     # Include team review requests
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
    --team)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--team requires a team name" >&2
        exit 1
      fi
      TEAMS+=("$2")
      shift 2
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

GITHUB_USER=$(get_github_user)

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
              submittedAt
              createdAt
            }
          }
          commits(last: 1) {
            nodes {
              commit {
                committedDate
              }
            }
          }
        }
      }
    }
  }
}
'

# Run a search query and return the raw GraphQL result
run_search() {
  local search_query="$1"
  gh api graphql \
    -f query="$QUERY" \
    -F searchQuery="$search_query" \
    -F limit="$LIMIT" \
    2>&1
}

# GitHub search combines multiple qualifiers with AND, so we need separate
# queries for personal and team review requests and then merge the results.
SEARCH_QUERIES=("is:pr is:open review-requested:@me org:${ORG}")
for team in "${TEAMS[@]}"; do
  SEARCH_QUERIES+=("is:pr is:open team-review-requested:${ORG}/${team} org:${ORG}")
done

# Execute all queries and merge results
ALL_RESULTS="[]"
for search_query in "${SEARCH_QUERIES[@]}"; do
  RESULT=$(run_search "$search_query") || {
    echo "GraphQL query failed: $RESULT" >&2
    exit 1
  }
  ALL_RESULTS=$(echo "$ALL_RESULTS" "$RESULT" | jq -s '
    .[0] + [.[1].data.search.edges[]?.node | select(. != null)]
  ')
done

# Deduplicate by PR URL
ALL_RESULTS=$(echo "$ALL_RESULTS" | jq 'unique_by(.url)')

# Keep PRs the user hasn't reviewed and PRs with commits newer than the user's
# last review. PENDING (draft) reviews have null submittedAt, so fall back to
# createdAt for the comparison.
PROCESSED=$(echo "$ALL_RESULTS" | jq --arg user "$GITHUB_USER" --argjson include_reviewed "$INCLUDE_REVIEWED" '
  map(
    (.reviews.nodes | map(select(.author.login == $user)) | last) as $last_review
    | (if $last_review == null then null
       else ($last_review.submittedAt // $last_review.createdAt) end) as $last_review_at
    | .commits.nodes[0].commit.committedDate as $last_commit_at
    | select($include_reviewed
            or $last_review_at == null
            or $last_commit_at > $last_review_at)
    | {
        number: .number,
        title: .title,
        url: .url,
        repo: .repository.nameWithOwner,
        author: .author.login,
        updated_at: .updatedAt,
        user_review_state: $last_review.state
      }
  )
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
  printf "%-6s %-25s %-50s %-15s %s\n" "PR#" "REPO" "TITLE" "STATUS" "AUTHOR"
  printf "%s\n" "$(printf '%.0s-' {1..135})"

  echo "$PROCESSED" | jq -r '.[] | [
    .number,
    (.repo | split("/")[1] | .[0:25]),
    (.title | .[0:50]),
    (.user_review_state // empty |
      if . == "CHANGES_REQUESTED" then "Changes req"
      elif . == "COMMENTED" then "Commented"
      elif . == "APPROVED" then "Approved"
      elif . == "DISMISSED" then "Dismissed"
      elif . == "PENDING" then "In progress"
      else . end
    ) // "Pending",
    .author
  ] | @tsv' | while IFS=$'\t' read -r num repo title status author; do
    printf "%-6s %-25s %-50s %-15s %s\n" "$num" "$repo" "$title" "$status" "$author"
  done

  echo ""
  echo "Run with --json for machine-readable output."
fi
