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
#   --priority-team TEAM  PRs authored by members of this team sort first
#   --sort KEY[:DIR]  Sort order: priority|repo|status|number, optional :asc
#                     or :desc (default: priority). priority groups by tier;
#                     any other key sorts the whole list globally.
#   --include-reviewed  Include PRs you've already reviewed
#   --all           Widen to the team's whole review queue (see below)
#   --pending       Only show PRs where you have a pending (draft) review
#   --draft         Alias for --pending
#   -h, --help      Show this help message
#
# --all widens the default reviewer-requested list to the team's review queue.
# With no --priority-team or --team it defaults to team-feature-flags, then
# folds in: PRs you've already reviewed (implies --include-reviewed), PRs
# requested from the team, and all open non-draft PRs authored by team members.
# This is a deliberate superset for triage, not a mirror of any project board.
#
# By default, results are grouped by priority tier, then most recently updated
# within each tier. An explicit --sort KEY orders the whole list by that key,
# with the priority tier as a secondary tiebreaker. Priority tiers:
#   1 - authored by a member of --priority-team
#   2 - conventional-commit title scoped to flags (e.g. "feat(flags):")
#   3 - everything else
#
# PR authors who belong to the org (--org, default PostHog) are flagged with a
# hedgehog (🦔) after their username in the AUTHOR column.
#
# The STATUS column reflects your review of each PR:
#   Not reviewed   - no review from you
#   Draft pending  - you have an unsubmitted draft review
#   Approved / Commented / Changes req / Dismissed - your last submitted
#       review state. By default these rows appear only when the PR has new
#       commits since that review; PRs whose draft or review is still current
#       are hidden unless you pass --include-reviewed.
#
# Output (JSON mode):
#   [
#     {
#       "number": 123,
#       "title": "PR title",
#       "url": "https://github.com/org/repo/pull/123",
#       "repo": "org/repo",
#       "author": "username",
#       "is_org_member": true,
#       "updated_at": "2024-01-15T10:30:00Z",
#       "user_review_state": null,
#       "priority": 3
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
ALL=false
TEAMS=()
PRIORITY_TEAM=""
# Team to fall back on when --all is given with no --priority-team or --team.
DEFAULT_TEAM="team-feature-flags"
# Sort spec: a JSON array of {key, dir} pairs in precedence order. Empty by
# default — the filter always appends the priority tier and recency — and
# filled in by --sort.
SORT_SPEC='[]'

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Find PRs awaiting your review in a GitHub organization.

Options:
  --org ORG           GitHub organization (default: PostHog)
  --limit N           Maximum number of PRs to return (default: 50)
  --json              Output raw JSON (default: formatted table)
  --team TEAM         Also find PRs requested from this team (repeatable)
  --priority-team TEAM  PRs authored by members of this team sort first
  --sort SPEC         Sort order as a comma-separated list of KEY[:DIR].
                      KEY is one of priority, repo, status, number; DIR is
                      asc (default) or desc. Earlier keys take precedence;
                      the priority tier and recency are always appended as
                      final tiebreakers. The default is priority, which
                      groups by tier (most recently updated within each).
  --include-reviewed  Include PRs you've already reviewed
  --all               Widen the list to the team's whole review queue. Defaults
                      to ${DEFAULT_TEAM} when no --priority-team or --team is
                      given. Implies --include-reviewed and
                      adds, for those teams: PRs requested from the team and all
                      open non-draft PRs authored by team members. Paginates so
                      a busy team's queue isn't truncated at --limit. A triage
                      superset, not a mirror of any project board.
  --pending           List every PR where you have a pending (draft) review.
                      Uses involves:@me and paginates, so it finds drafts even
                      on PRs you weren't requested to review. Ignores --team.
  --draft             Alias for --pending.
  -h, --help          Show this help message

Examples:
  $(basename "$0")                    # Find PRs in PostHog org
  $(basename "$0") --org myorg        # Find PRs in myorg
  $(basename "$0") --json             # Output as JSON for scripting
  $(basename "$0") --limit 10         # Limit to 10 PRs
  $(basename "$0") --team my-team     # Include team review requests
  $(basename "$0") --pending          # List your pending draft reviews
  $(basename "$0") --all --priority-team my-team  # Whole team review queue
  $(basename "$0") --sort repo        # Sort the whole list by repository name
  $(basename "$0") --sort number:desc # Sort by PR number, newest first
  $(basename "$0") --sort status,repo # Sort by status, then repository name
EOF
  exit 0
}

# Parse a --sort value (comma-separated KEY[:DIR] pairs) into a JSON array of
# {key, dir} objects, validating each. Prints the JSON on success; on a bad key
# or direction, prints an error and returns non-zero. Keys and dirs are checked
# against fixed allowlists, so the JSON is assembled directly (no escaping risk).
parse_sort_spec() {
  local spec="$1"
  local -a pairs objs=()
  IFS=',' read -ra pairs <<< "$spec"
  local pair key dir
  for pair in "${pairs[@]}"; do
    if [[ -z "$pair" ]]; then
      echo "--sort has an empty key in: $spec" >&2
      return 1
    fi
    key="${pair%%:*}"
    if [[ "$pair" == *:* ]]; then
      dir="${pair#*:}"
    else
      dir="asc"
    fi
    case "$key" in
      priority|repo|status|number) ;;
      *)
        echo "Invalid --sort key: $key (valid: priority, repo, status, number)" >&2
        return 1
        ;;
    esac
    case "$dir" in
      asc|desc) ;;
      *)
        echo "Invalid --sort direction: $dir (valid: asc, desc)" >&2
        return 1
        ;;
    esac
    objs+=("{\"key\":\"$key\",\"dir\":\"$dir\"}")
  done
  local IFS=,
  echo "[${objs[*]}]"
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
    --priority-team)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--priority-team requires a team name" >&2
        exit 1
      fi
      PRIORITY_TEAM="$2"
      shift 2
      ;;
    --sort)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        echo "--sort requires a value (comma-separated KEY[:asc|:desc])" >&2
        exit 1
      fi
      SORT_SPEC=$(parse_sort_spec "$2") || exit 1
      shift 2
      ;;
    --include-reviewed)
      INCLUDE_REVIEWED=true
      shift
      ;;
    --all)
      ALL=true
      INCLUDE_REVIEWED=true
      shift
      ;;
    --pending|--draft)
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

# --all needs a team to define whose work to widen to, and is meaningless in
# the pending-draft path (which has its own involves:@me query).
if [[ "$ALL" == "true" ]]; then
  if [[ "$PENDING_ONLY" == "true" ]]; then
    echo "--all and --pending/--draft cannot be combined" >&2
    exit 1
  fi
  if [[ -z "$PRIORITY_TEAM" && ${#TEAMS[@]} -eq 0 ]]; then
    PRIORITY_TEAM="$DEFAULT_TEAM"
    echo "--all with no team specified; defaulting to ${ORG}/${DEFAULT_TEAM}" >&2
  fi
fi

GITHUB_USER=$(get_github_user)

# Logins whose PRs get priority 1, as a JSON array for the jq filter.
TEAM_MEMBERS="[]"
if [[ -n "$PRIORITY_TEAM" ]]; then
  TEAM_MEMBERS=$(gh api "orgs/${ORG}/teams/${PRIORITY_TEAM}/members?per_page=100" --paginate --jq '[.[].login]' | jq -s 'add') || {
    echo "Could not list members of ${ORG}/${PRIORITY_TEAM}" >&2
    exit 1
  }
fi

# --all also lists every open non-draft PR authored by the team(s). Collect the
# union of member logins across the priority team and any --team(s); these drive
# the author-based search query below.
AUTHOR_MEMBERS=()
if [[ "$ALL" == "true" ]]; then
  declare -A seen_member=()
  for team in "$PRIORITY_TEAM" "${TEAMS[@]}"; do
    [[ -z "$team" ]] && continue
    members=$(gh api "orgs/${ORG}/teams/${team}/members?per_page=100" --paginate --jq '.[].login') || {
      echo "Could not list members of ${ORG}/${team}" >&2
      exit 1
    }
    while IFS= read -r login; do
      [[ -z "$login" || -n "${seen_member[$login]:-}" ]] && continue
      seen_member[$login]=1
      AUTHOR_MEMBERS+=("$login")
    done <<< "$members"
  done
fi

# Org members, used to flag PR authors who belong to the org with a hedgehog
# marker. This is a convenience: a fetch failure must never break the listing,
# so degrade to an empty array (mark nobody) instead of exiting.
ORG_MEMBERS=$(gh api "orgs/${ORG}/members?per_page=100" --paginate --jq '[.[].login]' | jq -s 'add') || {
  echo "Could not list members of ${ORG}; PR authors will not be flagged as org members." >&2
  ORG_MEMBERS="[]"
}

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

# Paginate when a mode can return more than --limit results: pending drafts and
# --all both gather a broad set. The default reviewer-requested mode returns the
# first page only, matching legacy behavior where --limit caps total results.
PAGINATE=false
if [[ "$PENDING_ONLY" == "true" || "$ALL" == "true" ]]; then
  PAGINATE=true
fi

# Run a search query and return a JSON array of PR nodes.
# When PAGINATE is true, follows the cursor until all results are fetched
# (capped at MAX_PAGES). Otherwise returns the first page only.
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

    if [[ "$PAGINATE" != "true" ]]; then
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
  # Self-authored PRs are excluded at the source so they don't consume result
  # slots that the --limit cap would otherwise give to reviewable PRs.
  SEARCH_QUERIES=("is:pr is:open review-requested:@me -author:@me org:${ORG}")

  # Teams to fold in via team-review-requested. --all also pulls in the priority
  # team, since it widens to that team's whole queue rather than just --team.
  REQUEST_TEAMS=("${TEAMS[@]}")
  if [[ "$ALL" == "true" && -n "$PRIORITY_TEAM" ]]; then
    REQUEST_TEAMS+=("$PRIORITY_TEAM")
  fi
  declare -A seen_request_team=()
  for team in "${REQUEST_TEAMS[@]}"; do
    [[ -n "${seen_request_team[$team]:-}" ]] && continue
    seen_request_team[$team]=1
    SEARCH_QUERIES+=("is:pr is:open team-review-requested:${ORG}/${team} -author:@me org:${ORG}")
  done

  # --all widens further to every open non-draft PR authored by a team member.
  # Multiple author: qualifiers are OR'd by GitHub search, so one query covers
  # the whole team. Drafts aren't ready for review, so exclude them.
  if [[ "$ALL" == "true" && ${#AUTHOR_MEMBERS[@]} -gt 0 ]]; then
    author_filter=""
    for login in "${AUTHOR_MEMBERS[@]}"; do
      author_filter+=" author:${login}"
    done
    SEARCH_QUERIES+=("is:pr is:open -is:draft -author:@me org:${ORG}${author_filter}")
  fi
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
  --argjson team_members "$TEAM_MEMBERS" \
  --argjson org_members "$ORG_MEMBERS" \
  --argjson sort_specs "$SORT_SPEC" \
  -f "${SCRIPT_DIR}/lib/review-filter.jq")

if [[ "$PENDING_ONLY" == "true" ]]; then
  PROCESSED=$(echo "$PROCESSED" | jq '[.[] | select(.user_review_state == "PENDING")]')
fi

# Count results. HIDDEN counts PRs dropped by the new-commits gate: you have
# a draft or submitted review and nothing changed since.
COUNT=$(echo "$PROCESSED" | jq 'length')
HIDDEN=0
if [[ "$INCLUDE_REVIEWED" != "true" ]]; then
  TOTAL=$(echo "$ALL_RESULTS" | jq 'length')
  HIDDEN=$((TOTAL - COUNT))
fi

if [[ "$JSON_OUTPUT" == "true" ]]; then
  echo "$PROCESSED"
else
  if [[ "$COUNT" -eq 0 ]]; then
    if [[ "$PENDING_ONLY" == "true" ]]; then
      echo "No pending draft reviews in ${ORG}."
    else
      echo "No PRs awaiting your review in ${ORG}."
      if [[ "$HIDDEN" -gt 0 ]]; then
        echo "${HIDDEN} PR(s) have your draft or review with no new commits since. Use --include-reviewed to see them."
      fi
    fi
    exit 0
  fi

  if [[ "$PENDING_ONLY" == "true" ]]; then
    echo "Found $COUNT pending draft review(s) in ${ORG}:"
  else
    echo "Found $COUNT PR(s) awaiting review in ${ORG}:"
  fi
  echo ""

  # Emit OSC 8 hyperlinks (PR# clickable in supporting terminals) only when
  # stdout is a TTY; piping stays clean.
  if [[ -t 1 ]]; then
    HYPERLINK=true
  else
    HYPERLINK=false
  fi

  # Print formatted table
  printf "%-6s %-3s %-25s %-50s %-15s %s\n" "PR#" "PRI" "REPO" "TITLE" "STATUS" "AUTHOR"
  printf "%s\n" "$(printf '%.0s-' {1..135})"

  echo "$PROCESSED" | jq -r '.[] | [
    .number,
    .priority,
    (.repo | split("/")[1] | .[0:25]),
    (.title | .[0:50]),
    (.user_review_state // empty |
      if . == "CHANGES_REQUESTED" then "Changes req"
      elif . == "COMMENTED" then "Commented"
      elif . == "APPROVED" then "Approved"
      elif . == "DISMISSED" then "Dismissed"
      elif . == "PENDING" then "Draft pending"
      else . end
    ) // "Not reviewed",
    .author,
    .is_org_member,
    .url
  ] | @tsv' | while IFS=$'\t' read -r num pri repo title status author is_member url; do
    # Flag org members with a hedgehog so PostHog authors stand out at a glance.
    author_display="$author"
    if [[ "$is_member" == "true" ]]; then
      author_display="$author 🦔"
    fi
    if [[ "$HYPERLINK" == "true" ]]; then
      # OSC 8 hyperlink: \e]8;;URL\e\\TEXT\e]8;;\e\\
      num_display=$(printf '\e]8;;%s\e\\%s\e]8;;\e\\' "$url" "$num")
      # Pad manually since printf %-6s counts the escape bytes.
      pad=$(( 6 - ${#num} ))
      (( pad < 0 )) && pad=0
      printf "%s%*s %-3s %-25s %-50s %-15s %s\n" "$num_display" "$pad" "" "$pri" "$repo" "$title" "$status" "$author_display"
    else
      printf "%-6s %-3s %-25s %-50s %-15s %s\n" "$num" "$pri" "$repo" "$title" "$status" "$author_display"
    fi
  done

  echo ""
  if [[ "$HIDDEN" -gt 0 ]]; then
    echo "${HIDDEN} more PR(s) have your draft or review with no new commits since. Use --include-reviewed to see them."
  fi
  echo "Run with --json for machine-readable output."
fi
