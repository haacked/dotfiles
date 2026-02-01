#!/usr/bin/env bash
# run-pr-reviews.sh - Orchestrate PR reviews using Claude Code
#
# Takes a list of PRs (from review-all-prs.sh or directly) and runs
# /review-code on each one sequentially.
#
# Usage:
#   run-pr-reviews.sh [OPTIONS]
#   review-all-prs.sh --json | run-pr-reviews.sh [OPTIONS]
#
# Options:
#   --auto              Run in automatic mode (calls review-all-prs.sh)
#   --max-prs N         Maximum PRs to review (default: 5)
#   --max-budget USD    Max budget per review in USD (default: 2.00)
#   --delay SECONDS     Delay between reviews in seconds (default: 30)
#   --dry-run           Show what would be reviewed without running
#   --org ORG           GitHub org for --auto mode (default: PostHog)
#   -h, --help          Show this help message
#
# State is tracked in ~/.local/state/review-all-prs/ to prevent
# duplicate reviews within a session.

set -euo pipefail

# Configuration
STATE_DIR="${HOME}/.local/state/review-all-prs"
MAX_PRS=5
MAX_BUDGET="2.00"
DELAY_SECONDS=30
DRY_RUN=false
AUTO_MODE=false
ORG="PostHog"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Orchestrate PR reviews using Claude Code's /review-code command.

Options:
  --auto              Run in automatic mode (calls review-all-prs.sh)
  --max-prs N         Maximum PRs to review (default: 5)
  --max-budget USD    Max budget per review in USD (default: 2.00)
  --delay SECONDS     Delay between reviews in seconds (default: 30)
  --dry-run           Show what would be reviewed without running
  --org ORG           GitHub org for --auto mode (default: PostHog)
  -h, --help          Show this help message

Examples:
  $(basename "$0") --auto                     # Auto-discover and review PRs
  $(basename "$0") --auto --max-prs 3         # Review up to 3 PRs
  $(basename "$0") --auto --dry-run           # Show what would be reviewed
  review-all-prs.sh --json | $(basename "$0") # Pipe PR list
EOF
  exit 0
}

log_info() {
  echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
  echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
  echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
  echo -e "${RED}[ERROR]${NC} $1" >&2
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --max-prs)
      MAX_PRS="$2"
      shift 2
      ;;
    --max-budget)
      MAX_BUDGET="$2"
      shift 2
      ;;
    --delay)
      DELAY_SECONDS="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --org)
      ORG="$2"
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

# Ensure state directory exists
mkdir -p "$STATE_DIR"

# Get today's date for session tracking
TODAY=$(date +%Y-%m-%d)
SESSION_FILE="${STATE_DIR}/session-${TODAY}.json"

# Initialize or load session
if [[ -f "$SESSION_FILE" ]]; then
  SESSION=$(cat "$SESSION_FILE")
else
  SESSION='{"reviewed": [], "failed": [], "skipped": []}'
fi

# Get list of PRs already reviewed today
get_reviewed_prs() {
  echo "$SESSION" | jq -r '.reviewed[]'
}

# Mark PR as reviewed
mark_reviewed() {
  local pr_url="$1"
  SESSION=$(echo "$SESSION" | jq --arg url "$pr_url" '.reviewed += [$url]')
  echo "$SESSION" > "$SESSION_FILE"
}

# Mark PR as failed
mark_failed() {
  local pr_url="$1"
  local reason="$2"
  SESSION=$(echo "$SESSION" | jq --arg url "$pr_url" --arg reason "$reason" \
    '.failed += [{"url": $url, "reason": $reason}]')
  echo "$SESSION" > "$SESSION_FILE"
}

# Check if PR was already reviewed today
is_reviewed() {
  local pr_url="$1"
  echo "$SESSION" | jq -e --arg url "$pr_url" '.reviewed | index($url) != null' > /dev/null 2>&1
}

# Get PR list - either from stdin or auto-discover
get_pr_list() {
  if [[ "$AUTO_MODE" == "true" ]]; then
    # Find the review-all-prs.sh script
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    DISCOVERY_SCRIPT="${SCRIPT_DIR}/review-all-prs.sh"

    if [[ ! -x "$DISCOVERY_SCRIPT" ]]; then
      log_error "Cannot find review-all-prs.sh at $DISCOVERY_SCRIPT"
      exit 1
    fi

    "$DISCOVERY_SCRIPT" --org "$ORG" --limit "$MAX_PRS" --json
  else
    # Read from stdin
    if [[ -t 0 ]]; then
      log_error "No input provided. Use --auto or pipe PR list from review-all-prs.sh"
      usage
    fi
    cat
  fi
}

# Check prerequisites
check_prerequisites() {
  # Check for claude CLI
  if ! command -v claude &> /dev/null; then
    log_error "Claude CLI not found. Please install it first."
    exit 1
  fi

  # Check for gh CLI
  if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) not found. Please install it first."
    exit 1
  fi

  # Check gh auth status
  if ! gh auth status &> /dev/null; then
    log_error "Not authenticated with GitHub. Run 'gh auth login' first."
    exit 1
  fi
}

# Run review for a single PR
run_review() {
  local pr_url="$1"
  local pr_number="$2"
  local pr_title="$3"

  log_info "Reviewing PR #${pr_number}: ${pr_title}"
  log_info "URL: ${pr_url}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: claude -p --max-budget-usd ${MAX_BUDGET} \"/review-code ${pr_url} --force\""
    return 0
  fi

  local start_time
  start_time=$(date +%s)

  # Run claude with timeout (15 minutes max per review)
  # Using -p (print) for non-interactive mode
  # Using --force to skip confirmation prompts
  local exit_code=0
  timeout 900 claude -p --max-budget-usd "$MAX_BUDGET" "/review-code ${pr_url} --force" || exit_code=$?

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  if [[ $exit_code -eq 0 ]]; then
    log_success "Review complete for PR #${pr_number} (${duration}s)"
    mark_reviewed "$pr_url"
    return 0
  elif [[ $exit_code -eq 124 ]]; then
    log_error "Review timed out for PR #${pr_number}"
    mark_failed "$pr_url" "timeout"
    return 1
  else
    log_error "Review failed for PR #${pr_number} (exit code: ${exit_code})"
    mark_failed "$pr_url" "exit_code_${exit_code}"
    return 1
  fi
}

# Main execution
main() {
  check_prerequisites

  log_info "Starting PR review session for ${TODAY}"
  log_info "Max PRs: ${MAX_PRS}, Max budget per review: \$${MAX_BUDGET}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Running in DRY RUN mode - no reviews will be executed"
  fi

  # Get PR list
  local pr_list
  pr_list=$(get_pr_list)

  # Count PRs
  local total_prs
  total_prs=$(echo "$pr_list" | jq 'length')

  if [[ "$total_prs" -eq 0 ]]; then
    log_info "No PRs to review."
    exit 0
  fi

  log_info "Found ${total_prs} PR(s) to review"

  # Track results
  local reviewed=0
  local failed=0
  local skipped=0

  # Process each PR
  echo "$pr_list" | jq -c '.[]' | head -n "$MAX_PRS" | while read -r pr; do
    local pr_url pr_number pr_title

    pr_url=$(echo "$pr" | jq -r '.url')
    pr_number=$(echo "$pr" | jq -r '.number')
    pr_title=$(echo "$pr" | jq -r '.title')

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Check if already reviewed today
    if is_reviewed "$pr_url"; then
      log_warn "Skipping PR #${pr_number} - already reviewed today"
      ((skipped++)) || true
      continue
    fi

    # Run the review
    if run_review "$pr_url" "$pr_number" "$pr_title"; then
      ((reviewed++)) || true
    else
      ((failed++)) || true
    fi

    # Delay between reviews (unless dry run or last PR)
    if [[ "$DRY_RUN" != "true" && "$DELAY_SECONDS" -gt 0 ]]; then
      log_info "Waiting ${DELAY_SECONDS}s before next review..."
      sleep "$DELAY_SECONDS"
    fi
  done

  # Print summary
  echo ""
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Review Session Complete"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  # Read final session state for summary
  if [[ -f "$SESSION_FILE" ]]; then
    local final_reviewed final_failed
    final_reviewed=$(jq '.reviewed | length' < "$SESSION_FILE")
    final_failed=$(jq '.failed | length' < "$SESSION_FILE")
    log_info "Total reviewed today: ${final_reviewed}"
    if [[ "$final_failed" -gt 0 ]]; then
      log_warn "Total failed today: ${final_failed}"
    fi
  fi

  log_info "Session state saved to: ${SESSION_FILE}"
}

main "$@"
