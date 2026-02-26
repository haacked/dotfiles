#!/usr/bin/env bash
# pr-review.sh - Manage pending GitHub PR reviews from the command line
#
# Subcommands:
#   pending [TARGET]   Find your pending (draft) reviews
#   submit  [PR]       Submit a pending review
#   help               Show usage
#
# See each subcommand's --help for details.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# ── Helpers ──────────────────────────────────────────────────────────────────

get_github_user() {
  gh api user --jq '.login' 2>/dev/null || {
    log_error "Could not determine GitHub username. Are you logged in with 'gh auth login'?"
    exit 1
  }
}

get_current_repo() {
  gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null || {
    log_error "Could not determine repository. Run from inside a repo or pass a full PR URL."
    exit 1
  }
}

# Parse a GitHub PR URL into REPO and PR_NUMBER variables.
# Returns 0 on success, 1 if the string is not a PR URL.
parse_pr_url() {
  local url="$1"
  if [[ "$url" =~ ^https://github\.com/([^/]+/[^/]+)/pull/([0-9]+) ]]; then
    REPO="${BASH_REMATCH[1]}"
    PR_NUMBER="${BASH_REMATCH[2]}"
    return 0
  fi
  return 1
}

# Fetch pending reviews for a single PR. Prints JSON array of matching reviews.
fetch_pending_reviews() {
  local repo="$1" pr="$2" user="$3"
  gh api "repos/${repo}/pulls/${pr}/reviews" \
    --jq "[.[] | select(.state == \"PENDING\" and .user.login == \"${user}\")]"
}

# ── cmd_pending ──────────────────────────────────────────────────────────────

cmd_pending_usage() {
  cat <<EOF
Usage: $(basename "$0") pending [TARGET] [OPTIONS]

Find your pending (draft) reviews on GitHub PRs.

TARGET can be:
  (none)              Search all repos you've interacted with
  GITHUB_PR_URL       Check a specific PR by URL
  NUMBER              Check PR #NUMBER in the current repo
  owner/repo          Search within a specific repository
  org                 Search within a GitHub organization

Options:
  --json              Output as JSON
  -h, --help          Show this help message

Examples:
  $(basename "$0") pending                                  # Search everywhere
  $(basename "$0") pending PostHog                          # Search PostHog org
  $(basename "$0") pending PostHog/posthog                  # Search specific repo
  $(basename "$0") pending 123                              # Check PR #123
  $(basename "$0") pending https://github.com/o/r/pull/123  # Check by URL
EOF
  exit 0
}

cmd_pending() {
  local target="" json_output=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --json)   json_output=true; shift ;;
      -h|--help) cmd_pending_usage ;;
      -*)       log_error "Unknown option: $1"; cmd_pending_usage ;;
      *)
        if [[ -n "$target" ]]; then
          log_error "Unexpected argument: $1"
          cmd_pending_usage
        fi
        target="$1"; shift
        ;;
    esac
  done

  local github_user
  github_user=$(get_github_user)

  # Disambiguate the target
  if [[ -z "$target" ]]; then
    pending_search "" "" "$github_user" "$json_output"
  elif parse_pr_url "$target"; then
    pending_single_pr "$REPO" "$PR_NUMBER" "$github_user" "$json_output"
  elif [[ "$target" =~ ^[0-9]+$ ]]; then
    local repo
    repo=$(get_current_repo)
    pending_single_pr "$repo" "$target" "$github_user" "$json_output"
  elif [[ "$target" =~ ^[^/]+/[^/]+$ ]]; then
    pending_search "repo:${target}" "$target" "$github_user" "$json_output"
  else
    pending_search "org:${target}" "$target" "$github_user" "$json_output"
  fi
}

# Check a single PR for pending reviews and display the result.
pending_single_pr() {
  local repo="$1" pr="$2" user="$3" json_output="$4"

  local reviews
  reviews=$(fetch_pending_reviews "$repo" "$pr" "$user") || {
    log_error "Failed to fetch reviews for ${repo}#${pr}"
    exit 1
  }

  local count
  count=$(echo "$reviews" | jq 'length')

  if [[ "$count" -eq 0 ]]; then
    if [[ "$json_output" == "true" ]]; then
      echo "[]"
    else
      echo "No pending reviews for ${user} on ${repo}#${pr}."
    fi
    return
  fi

  if [[ "$json_output" == "true" ]]; then
    # Fetch PR title for richer output
    local pr_title
    pr_title=$(gh api "repos/${repo}/pulls/${pr}" --jq '.title' 2>/dev/null || echo "")
    echo "$reviews" | jq --arg repo "$repo" --arg pr "$pr" --arg title "$pr_title" '
      map({
        repo: $repo,
        pr: ($pr | tonumber),
        title: $title,
        review_id: .id,
        comments: (.body | if . == "" or . == null then 0 else 1 end)
      })
    '
  else
    local review
    review=$(echo "$reviews" | jq 'first')
    local review_id comment_count
    review_id=$(echo "$review" | jq -r '.id')
    # Count inline comments via the review comments endpoint
    comment_count=$(gh api "repos/${repo}/pulls/${pr}/reviews/${review_id}/comments" --jq 'length' 2>/dev/null || echo "0")
    local pr_title
    pr_title=$(gh api "repos/${repo}/pulls/${pr}" --jq '.title' 2>/dev/null || echo "")

    echo "Pending review on ${repo}#${pr}:"
    echo ""
    echo "  Title:    ${pr_title}"
    echo "  Review:   ${review_id}"
    echo "  Comments: ${comment_count}"
    echo "  URL:      https://github.com/${repo}/pull/${pr}"
  fi
}

# Search for candidate PRs across repos/orgs, then check each for pending reviews.
pending_search() {
  local scope="$1" scope_label="$2" user="$3" json_output="$4"

  if [[ -z "$scope_label" ]]; then
    scope_label="all repos"
  fi

  log_info "Searching for pending reviews in ${scope_label}..."

  # Phase 1: find candidate PRs via gh search (reviewed-by and review-requested)
  local search_args=("is:pr" "is:open")
  if [[ -n "$scope" ]]; then
    search_args+=("$scope")
  fi

  local tmp_dir
  tmp_dir=$(mktemp -d)
  trap 'rm -rf "$tmp_dir"' EXIT

  # Run both searches and merge
  local prs_reviewed prs_requested
  prs_reviewed=$(gh search prs "${search_args[@]}" --reviewed-by="@me" --json repository,number,title --limit 100 2>/dev/null || echo "[]")
  prs_requested=$(gh search prs "${search_args[@]}" --review-requested="@me" --json repository,number,title --limit 100 2>/dev/null || echo "[]")

  # Merge, normalize, and deduplicate
  local candidates
  candidates=$(echo "$prs_reviewed" "$prs_requested" | jq -s '
    [.[0][], .[1][]] |
    map({
      repo: .repository.nameWithOwner,
      pr: .number,
      title: .title
    }) |
    unique_by([.repo, .pr])
  ')

  local candidate_count
  candidate_count=$(echo "$candidates" | jq 'length')

  if [[ "$candidate_count" -eq 0 ]]; then
    if [[ "$json_output" == "true" ]]; then
      echo "[]"
    else
      echo "No candidate PRs found in ${scope_label}."
    fi
    return
  fi

  log_info "Checking ${candidate_count} candidate PR(s) for pending reviews..."

  # Phase 2: check each candidate for PENDING reviews in parallel
  local i=0
  while IFS= read -r candidate; do
    local c_repo c_pr
    c_repo=$(echo "$candidate" | jq -r '.repo')
    c_pr=$(echo "$candidate" | jq -r '.pr')

    (
      local reviews
      reviews=$(fetch_pending_reviews "$c_repo" "$c_pr" "$user" 2>/dev/null || echo "[]")
      local count
      count=$(echo "$reviews" | jq 'length')
      if [[ "$count" -gt 0 ]]; then
        local review_id
        review_id=$(echo "$reviews" | jq -r 'first | .id')
        local comment_count
        comment_count=$(gh api "repos/${c_repo}/pulls/${c_pr}/reviews/${review_id}/comments" --jq 'length' 2>/dev/null || echo "0")
        echo "$candidate" | jq --arg rid "$review_id" --arg cc "$comment_count" \
          '. + {review_id: ($rid | tonumber), comments: ($cc | tonumber)}' \
          > "${tmp_dir}/${i}.json"
      fi
    ) &

    i=$((i + 1))
  done < <(echo "$candidates" | jq -c '.[]')

  wait

  # Collect results
  local results="[]"
  for f in "${tmp_dir}"/*.json; do
    [[ -f "$f" ]] || continue
    results=$(echo "$results" "$(cat "$f")" | jq -s '.[0] + [.[1]]')
  done

  local result_count
  result_count=$(echo "$results" | jq 'length')

  if [[ "$json_output" == "true" ]]; then
    echo "$results"
    return
  fi

  if [[ "$result_count" -eq 0 ]]; then
    echo "No pending reviews found in ${scope_label}."
    return
  fi

  echo "Found ${result_count} pending review(s):"
  echo ""
  printf "%-24s %-8s %-50s %s\n" "REPO" "PR#" "TITLE" "COMMENTS"
  printf "%s\n" "$(printf '%.0s-' {1..100})"

  echo "$results" | jq -r '.[] | [
    .repo,
    .pr,
    (.title | .[0:50]),
    .comments
  ] | @tsv' | while IFS=$'\t' read -r repo pr title comments; do
    printf "%-24s %-8s %-50s %s\n" "$repo" "$pr" "$title" "$comments"
  done
}

# ── cmd_submit ───────────────────────────────────────────────────────────────

cmd_submit_usage() {
  cat <<EOF
Usage: $(basename "$0") submit [PR] [OPTIONS]

Submit a pending PR review.

PR can be:
  (none)              Infer from current branch
  NUMBER              PR number in the current repo
  GITHUB_PR_URL       Full PR URL

Options:
  --approve           Submit as approval
  --comment           Submit as comment (default)
  --request-changes   Submit requesting changes
  --body TEXT         Add or replace the review body text
  --json              Output result as JSON
  -h, --help          Show this help message

Examples:
  $(basename "$0") submit                        # Submit review for current branch's PR
  $(basename "$0") submit 123 --approve          # Approve PR #123
  $(basename "$0") submit --request-changes      # Request changes on current branch's PR
  $(basename "$0") submit --body "Looks good!"   # Add body text
EOF
  exit 0
}

cmd_submit() {
  local event="COMMENT" body="" pr_arg="" json_output=false

  while [[ $# -gt 0 ]]; do
    case $1 in
      --approve)         event="APPROVE"; shift ;;
      --comment)         event="COMMENT"; shift ;;
      --request-changes) event="REQUEST_CHANGES"; shift ;;
      --body)
        if [[ $# -lt 2 ]]; then
          log_error "--body requires a text argument"
          exit 1
        fi
        body="$2"; shift 2
        ;;
      --json) json_output=true; shift ;;
      -h|--help) cmd_submit_usage ;;
      -*)
        log_error "Unknown option: $1"
        cmd_submit_usage
        ;;
      *)
        if [[ -n "$pr_arg" ]]; then
          log_error "Unexpected argument: $1"
          cmd_submit_usage
        fi
        pr_arg="$1"; shift
        ;;
    esac
  done

  local repo pr_number

  if [[ -z "$pr_arg" ]]; then
    local pr_json
    pr_json=$(gh pr view --json number 2>/dev/null) || {
      log_error "No PR found for the current branch. Specify a PR number or URL."
      exit 1
    }
    pr_number=$(echo "$pr_json" | jq -r '.number')
    repo=$(get_current_repo)
  elif parse_pr_url "$pr_arg"; then
    repo="$REPO"
    pr_number="$PR_NUMBER"
  elif [[ "$pr_arg" =~ ^[0-9]+$ ]]; then
    pr_number="$pr_arg"
    repo=$(get_current_repo)
  else
    log_error "Invalid PR argument: ${pr_arg}"
    log_error "Expected a PR number or URL."
    exit 1
  fi

  local github_user
  github_user=$(get_github_user)

  local pending_review
  pending_review=$(gh api "repos/${repo}/pulls/${pr_number}/reviews" \
    --jq "[.[] | select(.state == \"PENDING\" and .user.login == \"${github_user}\")] | first") || {
    log_error "Failed to fetch reviews for ${repo}#${pr_number}"
    exit 1
  }

  if [[ -z "$pending_review" || "$pending_review" == "null" ]]; then
    log_error "No pending review found for ${github_user} on ${repo}#${pr_number}"
    exit 1
  fi

  local review_id
  review_id=$(echo "$pending_review" | jq -r '.id')

  log_info "Found pending review ${review_id} on ${repo}#${pr_number}"
  log_info "Submitting as ${event}..."

  local request_body
  request_body=$(jq -n --arg event "$event" --arg body "$body" \
    'if $body == "" then {event: $event} else {event: $event, body: $body} end')

  local result
  result=$(gh api "repos/${repo}/pulls/${pr_number}/reviews/${review_id}/events" \
    --method POST \
    --input - <<< "$request_body" \
    --jq '{state: .state, html_url: .html_url}') || {
    log_error "Failed to submit review"
    exit 1
  }

  if [[ "$json_output" == "true" ]]; then
    echo "$result"
  else
    local state url
    state=$(echo "$result" | jq -r '.state')
    url=$(echo "$result" | jq -r '.html_url')
    log_success "Review submitted as ${state}"
    echo "$url"
  fi
}

# ── Main dispatch ────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [OPTIONS]

Manage pending GitHub PR reviews from the command line.

Commands:
  pending [TARGET]   Find your pending (draft) reviews
  submit  [PR]       Submit a pending review
  help               Show this help message

Run '$(basename "$0") <command> --help' for details on each command.
EOF
}

case "${1:-help}" in
  pending) shift; cmd_pending "$@" ;;
  submit)  shift; cmd_submit "$@" ;;
  help|-h|--help) usage ;;
  *)
    log_error "Unknown command: $1"
    usage >&2
    exit 1
    ;;
esac
