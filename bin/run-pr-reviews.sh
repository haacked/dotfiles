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
#   --max-budget USD    Max budget per review in USD (default: 10.00)
#   --delay SECONDS     Delay between reviews in seconds (default: 30)
#   --dry-run           Show what would be reviewed without running
#   --org ORG           GitHub org for --auto mode (default: PostHog)
#   --team TEAM         Also find PRs requested from this team (repeatable)
#   -h, --help          Show this help message
#
# State is tracked in ~/.local/state/review-all-prs/ to prevent
# duplicate reviews within a session.
#
# Review output is saved to ~/dev/ai/reviews/{repo}/pr-{number}-{date}.md

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/github.sh"
source "${SCRIPT_DIR}/lib/fs.sh"

# Configuration. STATE_DIR is overridable for tests; everything else is fixed.
STATE_DIR="${RUN_PR_REVIEWS_STATE_DIR:-${HOME}/.local/state/review-all-prs}"
REVIEWS_DIR="${HOME}/dev/ai/reviews"
MAX_PRS=5
MAX_BUDGET="10.00"
DELAY_SECONDS=30
REVIEW_TIMEOUT_SECONDS=900
# Force SIGKILL this many seconds after the initial SIGTERM if the review
# process ignores it. Without this, claude can ignore the timeout and run for
# hours of wall-clock time (especially on a sleeping laptop).
REVIEW_KILL_AFTER_SECONDS=60
# Quarantine a PR after this many consecutive failures across sessions, so a
# single broken PR does not jam the queue night after night.
MAX_CONSECUTIVE_FAILURES=2
# Quarantined PRs become eligible again after this many days, so a transient
# failure does not permanently exclude a PR.
QUARANTINE_DAYS=14
# Refuse to start a new review once the session has been running this long.
# Keeps an hourly tick from bleeding into the next one.
SESSION_BUDGET_SECONDS=3000
DRY_RUN=false
AUTO_MODE=false
ORG="PostHog"
TEAMS=()
REVIEW_FILE_PATH_SCRIPT="${HOME}/.claude/skills/review-code/scripts/review-file-path.sh"
FAILURES_FILE="${STATE_DIR}/pr-failures.json"
SESSION_START_TIME=0
LEDGER='{"version": 1, "prs": {}}'

usage() {
  cat <<EOF
Usage: $(basename "$0") [OPTIONS]

Orchestrate PR reviews using Claude Code's /review-code command.

Options:
  --auto              Run in automatic mode (calls review-all-prs.sh)
  --max-prs N         Maximum PRs to review (default: 5)
  --max-budget USD    Max budget per review in USD (default: 10.00)
  --delay SECONDS     Delay between reviews in seconds (default: 30)
  --dry-run           Show what would be reviewed without running
  --org ORG           GitHub org for --auto mode (default: PostHog)
  --team TEAM         Also find PRs requested from this team (repeatable)
  -h, --help          Show this help message

Output:
  Reviews are saved to ~/dev/ai/reviews/{repo}/pr-{number}-{date}.md
  If a review hits the budget limit or times out, this is noted in the file.

Examples:
  $(basename "$0") --auto                     # Auto-discover and review PRs
  $(basename "$0") --auto --max-prs 3         # Review up to 3 PRs
  $(basename "$0") --auto --dry-run           # Show what would be reviewed
  review-all-prs.sh --json | $(basename "$0") # Pipe PR list
EOF
  exit 0
}

# Parse arguments
while [[ $# -gt 0 ]]; do
  case $1 in
    --auto)
      AUTO_MODE=true
      shift
      ;;
    --max-prs)
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        log_error "--max-prs must be a positive integer"
        exit 1
      fi
      MAX_PRS="$2"
      shift 2
      ;;
    --max-budget)
      if [[ ! "$2" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "--max-budget must be a valid number (e.g., 2.00)"
        exit 1
      fi
      MAX_BUDGET="$2"
      shift 2
      ;;
    --delay)
      if [[ ! "$2" =~ ^[0-9]+$ ]]; then
        log_error "--delay must be a positive integer"
        exit 1
      fi
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
    --team)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        log_error "--team requires a team name"
        exit 1
      fi
      TEAMS+=("$2")
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
mkdir -p "$REVIEWS_DIR"

# Get today's date for session tracking
TODAY=$(date +%Y-%m-%d)
SESSION_FILE="${STATE_DIR}/session-${TODAY}.json"

# Initialize or load session
if [[ -f "$SESSION_FILE" ]]; then
  SESSION=$(cat "$SESSION_FILE")
else
  SESSION='{"reviewed": [], "failed": [], "skipped": [], "quarantined": [], "errors": []}'
fi

# Backfill .quarantined on legacy session files so jq += does not fail.
SESSION=$(echo "$SESSION" | jq '.quarantined = (.quarantined // [])')

if [[ -f "$FAILURES_FILE" ]]; then
  LEDGER=$(cat "$FAILURES_FILE")
fi

# Get list of PRs already reviewed today
get_reviewed_prs() {
  echo "$SESSION" | jq -r '.reviewed[] | if type == "object" then .url else . end'
}

# Mark PR as reviewed (in-memory only, saved at exit)
mark_reviewed() {
  local pr_url="$1"
  local review_file="${2:-}"
  SESSION=$(echo "$SESSION" | jq --arg url "$pr_url" --arg file "$review_file" \
    '.reviewed += [{"url": $url, "review_file": $file}]')
}

# Mark PR as failed (in-memory only, saved at exit)
mark_failed() {
  local pr_url="$1"
  local reason="$2"
  SESSION=$(echo "$SESSION" | jq --arg url "$pr_url" --arg reason "$reason" \
    '.failed += [{"url": $url, "reason": $reason}]')
}

# Mark PR as skipped (in-memory only, saved at exit). Deduplicates so that
# repeated hourly runs don't bloat the skipped list with the same URLs.
mark_skipped() {
  local pr_url="$1"
  SESSION=$(echo "$SESSION" | jq --arg url "$pr_url" \
    'if (.skipped | index($url)) then . else .skipped += [$url] end')
}

# Record an error in the session so that empty sessions explain why no
# reviews were attempted (e.g. missing prerequisites). Deduplicates by
# message, incrementing a count for repeated occurrences.
mark_error() {
  local message="$1"
  SESSION=$(echo "$SESSION" | jq --arg msg "$message" \
    'if (.errors | map(.message) | index($msg)) then
       .errors |= map(if .message == $msg then .count += 1 else . end)
     else
       .errors += [{"message": $msg, "count": 1}]
     end')
}

mark_quarantined() {
  local pr_url="$1"
  local reason="$2"
  SESSION=$(echo "$SESSION" | jq --arg url "$pr_url" --arg reason "$reason" \
    'if (.quarantined | map(.url) | index($url)) then .
     else .quarantined += [{"url": $url, "reason": $reason}] end')
}

save_session() {
  atomic_write "$SESSION_FILE" <<<"$SESSION"
}

# ── Persistent per-PR failure ledger ──────────────────────────────────────
#
# Tracks consecutive failures across sessions so one stuck PR cannot jam the
# queue every night. Stored at $FAILURES_FILE as:
#   { version, prs: { <url>: { failures, first_failure, last_failure,
#     last_reason } } }
# Cached in $LEDGER for the run; persisted by the EXIT trap.

save_failures() {
  atomic_write "$FAILURES_FILE" <<<"$LEDGER"
}

record_failure() {
  local pr_url="$1"
  local reason="$2"
  local now
  now=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  LEDGER=$(echo "$LEDGER" | jq \
    --arg url "$pr_url" --arg reason "$reason" --arg now "$now" \
    '.prs[$url] = {
       failures: ((.prs[$url].failures // 0) + 1),
       first_failure: (.prs[$url].first_failure // $now),
       last_failure: $now,
       last_reason: $reason
     }')
}

# Clears the PR's streak so the ledger only reflects currently-failing PRs.
record_success() {
  local pr_url="$1"
  LEDGER=$(echo "$LEDGER" | jq --arg url "$pr_url" 'del(.prs[$url])')
}

# Echoes a human reason and returns 0 when the PR is quarantined: at least
# MAX_CONSECUTIVE_FAILURES and last failure within QUARANTINE_DAYS. Returns 1
# (no output) otherwise. The cool-down lets transient failures heal on their
# own.
is_quarantined() {
  local pr_url="$1"
  local entry
  entry=$(echo "$LEDGER" | jq -c --arg url "$pr_url" '.prs[$url] // empty')
  if [[ -z "$entry" ]]; then
    return 1
  fi
  local failures last_failure last_reason
  IFS=$'\t' read -r failures last_failure last_reason < <(
    echo "$entry" | jq -r '[.failures, .last_failure, (.last_reason // "unknown")] | @tsv')
  if [[ "$failures" -lt "$MAX_CONSECUTIVE_FAILURES" ]]; then
    return 1
  fi
  # BSD date; timestamp is always UTC ISO8601 with trailing Z.
  local last_epoch now_epoch age_days
  last_epoch=$(date -juf "%Y-%m-%dT%H:%M:%SZ" "$last_failure" +%s 2>/dev/null) || return 1
  now_epoch=$(date -u +%s)
  age_days=$(( (now_epoch - last_epoch) / 86400 ))
  if [[ "$age_days" -ge "$QUARANTINE_DAYS" ]]; then
    return 1
  fi
  echo "${failures} consecutive failures (last: ${last_reason}, ${age_days}d ago)"
}

# Combined session+ledger updates so callers can't drift the two stores.
fail_review() {
  mark_failed "$1" "$2"
  record_failure "$1" "$2"
}
succeed_review() {
  mark_reviewed "$1" "$2"
  record_success "$1"
}

# Check if PR was already reviewed today
is_reviewed() {
  local pr_url="$1"
  echo "$SESSION" | jq -e --arg url "$pr_url" \
    '.reviewed | map(if type == "object" then .url else . end) | index($url) != null' > /dev/null 2>&1
}

# Check if a review file already exists for a PR
# Uses the review-code skill's path resolution script
review_exists() {
  local pr_number="$1"
  local pr_repo="$2"

  if [[ ! -x "$REVIEW_FILE_PATH_SCRIPT" ]]; then
    # Script not available, fall back to not skipping
    return 1
  fi

  local org repo
  org="${pr_repo%/*}"
  repo="${pr_repo#*/}"

  local review_info
  review_info=$("$REVIEW_FILE_PATH_SCRIPT" --org "$org" --repo "$repo" "pr-${pr_number}" 2>/dev/null) || return 1

  local file_exists
  file_exists=$(echo "$review_info" | jq -r '.file_exists')
  [[ "$file_exists" == "true" ]]
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

    local team_args=()
    for team in "${TEAMS[@]}"; do
      team_args+=(--team "$team")
    done

    "$DISCOVERY_SCRIPT" --org "$ORG" --limit "$MAX_PRS" --json "${team_args[@]}"
  else
    # Read from stdin
    if [[ -t 0 ]]; then
      log_error "No input provided. Use --auto or pipe PR list from review-all-prs.sh"
      usage
    fi
    cat
  fi
}

# Check prerequisites. Failures are recorded in the session so that
# recent-reviews.sh can show why a session produced no reviews.
check_prerequisites() {
  # Check for claude CLI
  if ! command -v claude &> /dev/null; then
    log_error "Claude CLI not found. Please install it first."
    mark_error "Claude CLI not found"
    exit 1
  fi

  # Check for gh CLI
  if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) not found. Please install it first."
    mark_error "GitHub CLI (gh) not found"
    exit 1
  fi

  # Check for timeout command (coreutils)
  if ! command -v timeout &> /dev/null; then
    log_error "timeout command not found. Install coreutils: brew install coreutils"
    mark_error "timeout command not found"
    exit 1
  fi

  # Check gh auth status
  if ! gh auth status &> /dev/null; then
    log_error "Not authenticated with GitHub. Run 'gh auth login' first."
    mark_error "GitHub authentication failed"
    exit 1
  fi
}

# Append a tail of the agent transcript to the review file when a review
# times out, so we can see what claude was doing when it got stuck. Keeps
# the snippet bounded so we don't double the size of long transcripts.
append_timeout_diagnostics() {
  local review_file="$1"
  local output_file="$2"
  local exit_code="$3"
  local kill_label=""
  if [[ "$exit_code" -eq 137 ]]; then
    kill_label=" (SIGKILL after ${REVIEW_KILL_AFTER_SECONDS}s grace)"
  fi
  {
    echo "- **Status:** ⚠️ INCOMPLETE — Timed out after ${REVIEW_TIMEOUT_SECONDS}s${kill_label}"
    echo ""
    echo "> **Note:** This review did not complete due to timeout. Consider reviewing manually."
    echo ""
    echo "### Last 200 lines of agent transcript"
    echo ""
    echo '```'
    tail -n 200 "$output_file"
    echo '```'
  } >> "$review_file"
}

# Run review for a single PR
run_review() {
  local pr_url="$1"
  local pr_number="$2"
  local pr_title="$3"
  local pr_repo="$4"

  # Validate GitHub PR URL format
  if [[ ! "$pr_url" =~ ^https://github\.com/[^/]+/[^/]+/pull/[0-9]+$ ]]; then
    log_error "Invalid GitHub PR URL: ${pr_url}"
    return 1
  fi

  log_info "Reviewing PR #${pr_number}: ${pr_title}"
  log_info "URL: ${pr_url}"

  # Set up review output file
  local repo_name
  repo_name=$(echo "$pr_repo" | tr '/' '-')
  local review_dir="${REVIEWS_DIR}/${repo_name}"
  local review_file="${review_dir}/pr-${pr_number}-$(date +%Y%m%d).md"
  mkdir -p "$review_dir"

  # --append targets the skill's persistent per-PR file, which is separate
  # from the date-stamped file this orchestrator writes.
  local prompt="/review-code ${pr_url} --force --draft"
  if review_exists "$pr_number" "$pr_repo"; then
    prompt+=" --append"
    log_info "Existing review file detected, will append"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Would run: claude -p --max-budget-usd ${MAX_BUDGET} \"${prompt}\""
    log_info "[DRY RUN] Output would be saved to: ${review_file}"
    return 0
  fi

  # Write review header
  {
    echo "# Review: ${pr_title}"
    echo ""
    echo "- **PR:** [#${pr_number}](${pr_url})"
    echo "- **Repository:** ${pr_repo}"
    echo "- **Date:** $(date '+%Y-%m-%d %H:%M:%S')"
    echo "- **Budget:** \$${MAX_BUDGET}"
    echo ""
    echo "---"
    echo ""
  } > "$review_file"

  local start_time
  start_time=$(date +%s)

  # caffeinate -i prevents idle sleep so the timeout measures real wall-clock
  # time. timeout --kill-after fires SIGKILL if claude ignores SIGTERM, so a
  # stuck review cannot run for hours.
  local exit_code=0
  local output_file
  output_file=$(mktemp)
  start_heartbeat 30 "Claude reviewing PR #${pr_number}"
  set +o pipefail
  caffeinate -i timeout --kill-after="$REVIEW_KILL_AFTER_SECONDS" \
    "$REVIEW_TIMEOUT_SECONDS" \
    claude -p --max-budget-usd "$MAX_BUDGET" "$prompt" 2>&1 | tee "$output_file" || true
  exit_code=${PIPESTATUS[0]}
  set -o pipefail
  stop_heartbeat

  local end_time
  end_time=$(date +%s)
  local duration=$((end_time - start_time))

  # Append Claude's output to review file
  cat "$output_file" >> "$review_file"

  # Check for budget exhaustion in output
  local budget_exhausted=false
  if grep -qi "budget" "$output_file" && grep -qi -E "(exhaust|limit|exceed|reach)" "$output_file"; then
    budget_exhausted=true
  fi

  # Append status footer
  {
    echo ""
    echo "---"
    echo ""
    echo "## Review Metadata"
    echo ""
    echo "- **Duration:** ${duration}s"
    echo "- **Exit code:** ${exit_code}"
  } >> "$review_file"

  if [[ "$budget_exhausted" == "true" ]]; then
    {
      echo "- **Status:** ⚠️ INCOMPLETE — Budget exhausted (\$${MAX_BUDGET} limit reached)"
      echo ""
      echo "> **Note:** This review did not complete due to budget constraints. Consider reviewing manually or increasing the budget limit."
    } >> "$review_file"
    log_warn "Review incomplete for PR #${pr_number} — budget exhausted"
    log_info "Review saved to: ${review_file}"
    fail_review "$pr_url" "budget_exhausted"
    rm -f "$output_file"
    return 1
  elif [[ $exit_code -eq 0 ]]; then
    echo "- **Status:** ✅ Complete" >> "$review_file"
    log_success "Review complete for PR #${pr_number} (${duration}s)"
    log_info "Review saved to: ${review_file}"
    succeed_review "$pr_url" "$review_file"
    rm -f "$output_file"
    return 0
  elif [[ $exit_code -eq 124 || $exit_code -eq 137 ]]; then
    # 124 = SIGTERM-and-exit; 137 = SIGKILL via --kill-after.
    append_timeout_diagnostics "$review_file" "$output_file" "$exit_code"
    log_error "Review timed out for PR #${pr_number}"
    log_info "Review saved to: ${review_file}"
    fail_review "$pr_url" "timeout"
    rm -f "$output_file"
    return 1
  else
    echo "- **Status:** ❌ Failed (exit code: ${exit_code})" >> "$review_file"
    log_error "Review failed for PR #${pr_number} (exit code: ${exit_code})"
    log_info "Review saved to: ${review_file}"
    fail_review "$pr_url" "exit_code_${exit_code}"
    rm -f "$output_file"
    return 1
  fi
}

# Main execution
main() {
  trap 'stop_heartbeat; save_session; save_failures' EXIT

  check_prerequisites

  SESSION_START_TIME=$(date +%s)
  log_info "Starting PR review session for ${TODAY}"
  log_info "Max PRs: ${MAX_PRS}, Max budget per review: \$${MAX_BUDGET}"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Running in DRY RUN mode - no reviews will be executed"
  fi

  # Get current GitHub username (for skipping self-authored PRs)
  local github_user
  github_user=$(get_github_user)

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

  # Process via process substitution to keep variables in the parent shell.
  while read -r pr; do
    local pr_url pr_number pr_title pr_repo pr_author
    IFS=$'\t' read -r pr_url pr_number pr_title pr_repo pr_author < <(echo "$pr" | jq -r '[.url, (.number | tostring), .title, .repo, .author] | @tsv')

    # Bail out before logging the separator if the next launchd tick is
    # imminent; remaining PRs run on the next tick instead of bleeding into it.
    local now elapsed
    now=$(date +%s)
    elapsed=$(( now - SESSION_START_TIME ))
    if [[ "$elapsed" -ge "$SESSION_BUDGET_SECONDS" ]]; then
      log_warn "Session budget reached (${elapsed}s ≥ ${SESSION_BUDGET_SECONDS}s); stopping early"
      mark_error "session budget reached after ${elapsed}s"
      break
    fi

    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "$pr_author" == "$github_user" ]]; then
      log_warn "Skipping PR #${pr_number} - authored by you"
      mark_skipped "$pr_url"
      ((skipped++)) || true
      continue
    fi

    if is_reviewed "$pr_url"; then
      log_warn "Skipping PR #${pr_number}, already reviewed today"
      mark_skipped "$pr_url"
      ((skipped++)) || true
      continue
    fi

    local quarantine_reason
    if quarantine_reason=$(is_quarantined "$pr_url") && [[ -n "$quarantine_reason" ]]; then
      log_warn "Skipping PR #${pr_number}, quarantined: ${quarantine_reason}"
      mark_quarantined "$pr_url" "$quarantine_reason"
      ((skipped++)) || true
      continue
    fi

    if run_review "$pr_url" "$pr_number" "$pr_title" "$pr_repo"; then
      ((reviewed++)) || true
    else
      ((failed++)) || true
    fi

    # Delay between reviews (unless dry run or last PR)
    if [[ "$DRY_RUN" != "true" && "$DELAY_SECONDS" -gt 0 ]]; then
      log_info "Waiting ${DELAY_SECONDS}s before next review..."
      sleep "$DELAY_SECONDS"
    fi
  done < <(echo "$pr_list" | jq -c '.[]' | head -n "$MAX_PRS")

  # Print summary
  log_section "Review Session Complete"

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
