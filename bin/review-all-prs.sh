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
#   --pending       Only show PRs where you have a pending (draft) review
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
PENDING_ONLY=false
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
  --pending           List every PR where you have a pending (draft) review.
                      Uses involves:@me and paginates, so it finds drafts even
                      on PRs you weren't requested to review. Ignores --team.
  -h, --help          Show this help message

Examples:
  $(basename "$0")                    # Find PRs in PostHog org
  $(basename "$0") --org myorg        # Find PRs in myorg
  $(basename "$0") --json             # Output as JSON for scripting
  $(basename "$0") --limit 10         # Limit to 10 PRs
  $(basename "$0") --team my-team     # Include team review requests
  $(basename "$0") --pending          # List your pending draft reviews
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
    --pending)
      PENDING_ONLY=true
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
query($searchQuery: String!, $limit: Int!, $cursor: String) {
  search(query: $searchQuery, type: ISSUE, first: $limit, after: $cursor) {
    pageInfo {
      hasNextPage
      endCursor
    }
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

# Run a search query and return a JSON array of PR nodes.
# When PENDING_ONLY is true, paginates until all results are fetched (capped
# at MAX_PAGES). Otherwise returns the first page only, matching legacy
# behavior where --limit caps total results.
MAX_PAGES=20
run_search() {
  local search_query="$1"
  local cursor=""
  local merged="[]"
  local page page_nodes has_next pages=0

  while (( pages < MAX_PAGES )); do
    local args=(-f query="$QUERY" -F searchQuery="$search_query" -F limit="$LIMIT")
    if [[ -n "$cursor" ]]; then
      args+=(-F cursor="$cursor")
    fi

    page=$(gh api graphql "${args[@]}" 2>&1) || {
      echo "GraphQL query failed: $page" >&2
      return 1
    }

    page_nodes=$(echo "$page" | jq '[.data.search.edges[]?.node | select(. != null)]')
    merged=$(jq -s '.[0] + .[1]' <(echo "$merged") <(echo "$page_nodes"))
    pages=$((pages + 1))

    if [[ "$PENDING_ONLY" != "true" ]]; then
      break
    fi

    has_next=$(echo "$page" | jq -r '.data.search.pageInfo.hasNextPage')
    if [[ "$has_next" != "true" ]]; then
      break
    fi
    cursor=$(echo "$page" | jq -r '.data.search.pageInfo.endCursor')
  done

  echo "$merged"
}

# Pending mode wants every PR you've engaged with so we can find drafts on
# PRs where you weren't a requested reviewer; involves:@me covers that.
# --team is irrelevant in this mode and is silently ignored.
if [[ "$PENDING_ONLY" == "true" ]]; then
  SEARCH_QUERIES=("is:pr is:open involves:@me org:${ORG}")
else
  # GitHub search combines multiple qualifiers with AND, so we need separate
  # queries for personal and team review requests and then merge the results.
  SEARCH_QUERIES=("is:pr is:open review-requested:@me org:${ORG}")
  for team in "${TEAMS[@]}"; do
    SEARCH_QUERIES+=("is:pr is:open team-review-requested:${ORG}/${team} org:${ORG}")
  done
fi

# Execute all queries and merge results
ALL_RESULTS="[]"
for search_query in "${SEARCH_QUERIES[@]}"; do
  NODES=$(run_search "$search_query") || exit 1
  ALL_RESULTS=$(jq -s '.[0] + .[1]' <(echo "$ALL_RESULTS") <(echo "$NODES"))
done

# Deduplicate by PR URL
ALL_RESULTS=$(echo "$ALL_RESULTS" | jq 'unique_by(.url)')

PROCESSED=$(echo "$ALL_RESULTS" | jq \
  --arg user "$GITHUB_USER" \
  --argjson include_reviewed "$INCLUDE_REVIEWED" \
  -f "${SCRIPT_DIR}/lib/review-filter.jq")

if [[ "$PENDING_ONLY" == "true" ]]; then
  PROCESSED=$(echo "$PROCESSED" | jq '[.[] | select(.user_review_state == "PENDING")]')
fi

# Count results
COUNT=$(echo "$PROCESSED" | jq 'length')

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "$PROCESSED"
else
  if [[ "$COUNT" -eq 0 ]]; then
    if [[ "$PENDING_ONLY" == "true" ]]; then
      echo "No pending draft reviews in ${ORG}."
    else
      echo "No PRs awaiting your review in ${ORG}."
    fi
    exit 0
  fi

  if [[ "$PENDING_ONLY" == "true" ]]; then
    echo "Found $COUNT pending draft review(s) in ${ORG}:"
  else
    echo "Found $COUNT PR(s) awaiting review in ${ORG}:"
  fi
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
