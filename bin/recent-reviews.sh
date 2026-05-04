#!/usr/bin/env bash
# recent-reviews.sh - Show recent PR review activity
#
# Reads session state files to display which PRs were reviewed, failed,
# or skipped over recent days. For reviewed PRs, shows the path to the
# local review markdown file.
#
# Usage:
#   recent-reviews.sh [OPTIONS]
#
# Options:
#   --days N     Number of days to look back (default: 7)
#   -h, --help   Show this help message

set -euo pipefail

# Source shared logging utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# Configuration
STATE_DIR="${HOME}/.local/state/review-all-prs"
REVIEWS_DIR="${HOME}/dev/ai/reviews"
DAYS=7

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Show recent PR review activity from scheduled review sessions.

Options:
  --days N     Number of days to look back (default: 7)
  -h, --help   Show this help message

Examples:
  $(basename "$0")            # Show last 7 days of reviews
  $(basename "$0") --days 3   # Show last 3 days of reviews
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --days)
      if [[ $# -lt 2 ]] || [[ ! "$2" =~ ^[0-9]+$ ]]; then
        log_error "--days must be a positive integer"
        exit 1
      fi
      DAYS="$2"
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage
      ;;
  esac
done

# Check prerequisites
if ! command -v jq &> /dev/null; then
  log_error "jq is required but not installed."
  exit 1
fi

if [[ ! -d "$STATE_DIR" ]]; then
  log_warn "No session state directory found at ${STATE_DIR}"
  log_info "No reviews have been run yet."
  exit 0
fi

# Find the review file for a given PR URL and date.
# Searches for pr-{number}-{YYYYMMDD}.md in the {org}-{repo} subdirectory.
find_review_file() {
  local pr_url="$1"
  local session_date="$2"

  local org repo pr_number
  if [[ "$pr_url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
    org="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
    pr_number="${BASH_REMATCH[3]}"
  else
    return
  fi

  local repo_dir="${REVIEWS_DIR}/${org}-${repo}"
  local date_compact="${session_date//-/}"
  local review_file="${repo_dir}/pr-${pr_number}-${date_compact}.md"

  if [[ -f "$review_file" ]]; then
    echo "$review_file"
    return
  fi

  # Fallback: look for any review file matching this PR number in the repo dir
  if [[ -d "$repo_dir" ]]; then
    local match
    match=$(find "$repo_dir" -name "pr-${pr_number}-*.md" -print -quit 2>/dev/null)
    if [[ -n "$match" ]]; then
      echo "$match"
      return
    fi
  fi
}

# Display a single day's review activity
show_day() {
  local session_date="$1"
  local session_file="${STATE_DIR}/session-${session_date}.json"

  echo "${session_date}"

  if [[ ! -f "$session_file" ]]; then
    echo "  (no session)"
    echo ""
    return
  fi

  local session
  session=$(cat "$session_file")

  local reviewed_count failed_count skipped_count quarantined_count error_count
  IFS=$'\t' read -r reviewed_count failed_count skipped_count quarantined_count error_count < <(
    echo "$session" | jq -r '[
      (.reviewed | length),
      (.failed | length),
      (.skipped | length),
      (.quarantined // [] | length),
      (.errors // [] | length)
    ] | @tsv')
  if [[ "$error_count" -gt 0 ]]; then
    while IFS=$'\t' read -r msg count; do
      if [[ "$count" -gt 1 ]]; then
        echo "  ⚠️  ${msg} (×${count})"
      else
        echo "  ⚠️  ${msg}"
      fi
    done < <(echo "$session" | jq -r '.errors[] | [.message, (.count // 1 | tostring)] | @tsv')
  fi

  if [[ "$reviewed_count" -eq 0 && "$failed_count" -eq 0 && "$skipped_count" -eq 0 && "$quarantined_count" -eq 0 && "$error_count" -eq 0 ]]; then
    echo "  (no reviews)"
    echo ""
    return
  fi

  # Show reviewed PRs. Session entries may be objects (with url and review_file)
  # or plain strings (legacy format).
  if [[ "$reviewed_count" -gt 0 ]]; then
    while IFS=$'\t' read -r pr_url review_file; do
      echo "  ✅ ${pr_url}"
      if [[ -z "$review_file" || "$review_file" == "null" ]]; then
        review_file=$(find_review_file "$pr_url" "$session_date")
      fi
      if [[ -n "$review_file" && -f "$review_file" ]]; then
        echo "     Review: ${review_file/#$HOME/~}"
      fi
    done < <(echo "$session" | jq -r '.reviewed[] | if type == "object" then [.url, .review_file] | @tsv else [., ""] | @tsv end')
  fi

  # Show failed PRs
  if [[ "$failed_count" -gt 0 ]]; then
    while IFS=$'\t' read -r url reason; do
      echo "  ❌ ${url} (${reason})"
    done < <(echo "$session" | jq -r '.failed[] | [.url, .reason] | @tsv')
  fi

  # Show skipped PRs
  if [[ "$skipped_count" -gt 0 ]]; then
    while IFS= read -r pr_url; do
      echo "  ⏭  ${pr_url} (already reviewed)"
    done < <(echo "$session" | jq -r '.skipped[]')
  fi

  # Show quarantined PRs (skipped because of repeated prior failures)
  if [[ "$quarantined_count" -gt 0 ]]; then
    while IFS=$'\t' read -r pr_url reason; do
      echo "  🚫 ${pr_url} (quarantined: ${reason})"
    done < <(echo "$session" | jq -r '.quarantined[] | [.url, .reason] | @tsv')
  fi

  echo ""
}

# Main: iterate over recent days
found_any=false
for ((i = 0; i < DAYS; i++)); do
  if date --version &> /dev/null 2>&1; then
    # GNU date
    session_date=$(date -d "-${i} days" +%Y-%m-%d)
  else
    # BSD date (macOS)
    session_date=$(date -v-"${i}"d +%Y-%m-%d)
  fi

  session_file="${STATE_DIR}/session-${session_date}.json"
  if [[ -f "$session_file" ]]; then
    found_any=true
    show_day "$session_date"
  fi
done

if [[ "$found_any" != "true" ]]; then
  log_info "No review sessions found in the last ${DAYS} day(s)."
fi
