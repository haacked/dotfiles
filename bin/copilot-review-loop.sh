#!/usr/bin/env bash
# copilot-review-loop.sh - Automate Copilot PR review feedback cycles
#
# Requests a Copilot review, evaluates the comments with Claude, fixes legit
# issues, replies to non-legit ones, pushes, and repeats until Copilot has
# no new comments or max rounds are reached.
#
# Usage:
#   copilot-review-loop.sh <pr-url> [OPTIONS]
#
# Must be run from within a checkout of the PR's repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# ── Configuration Defaults ───────────────────────────────────────────────────

MAX_ROUNDS=5
MAX_BUDGET="5.00"
TIMEOUT=600
POLL_INTERVAL=15
POLL_TIMEOUT=600
DRY_RUN=false
STATE_DIR="${HOME}/.local/state/copilot-review-loop"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") <pr-url> [OPTIONS]

Automate Copilot PR review feedback cycles. Requests a Copilot review,
evaluates comments with Claude, fixes legit issues, replies to non-legit
ones, pushes, and repeats until Copilot has no new comments.

Must be run from within a checkout of the PR's repository.

Options:
  --max-rounds N        Max review-fix rounds (default: 5)
  --max-budget USD      Claude budget per round in USD (default: 5.00)
  --timeout SECONDS     Claude timeout per round (default: 600)
  --poll-interval SECS  Seconds between review checks (default: 15)
  --poll-timeout SECS   Max wait for Copilot review (default: 600)
  --dry-run             Show what would happen without executing
  -h, --help            Show this help message

Examples:
  $(basename "$0") https://github.com/owner/repo/pull/123
  $(basename "$0") https://github.com/owner/repo/pull/123 --max-rounds 3
  $(basename "$0") https://github.com/owner/repo/pull/123 --dry-run
EOF
  exit 0
}

# ── Helpers ──────────────────────────────────────────────────────────────────

# Parse a GitHub PR URL into OWNER, REPO_NAME, REPO, and PR_NUMBER.
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

# Validate that the working directory is a checkout of the expected repo.
validate_working_directory() {
  local expected="$1"
  local current
  current=$(gh repo view --json nameWithOwner -q '.nameWithOwner' 2>/dev/null) || {
    log_error "Could not determine repository. Run this from inside a checkout of ${expected}."
    exit 1
  }
  if [[ "${current,,}" != "${expected,,}" ]]; then
    log_error "Working directory is ${current}, but PR belongs to ${expected}."
    log_error "Run this from a checkout of ${expected}."
    exit 1
  fi
}

# Compute SHA-256 hash of a normalized (trimmed, lowercased) comment body.
hash_comment() {
  local body="$1"
  echo -n "$body" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | shasum -a 256 \
    | cut -d' ' -f1
}

# ── State Management ─────────────────────────────────────────────────────────

load_state() {
  STATE_FILE="${STATE_DIR}/${OWNER}-${REPO_NAME}-${PR_NUMBER}.json"
  mkdir -p "$STATE_DIR"
  if [[ -f "$STATE_FILE" ]]; then
    STATE=$(cat "$STATE_FILE")
  else
    STATE='{"dismissed_comments":[],"rounds":[]}'
  fi
}

save_state() {
  local tmp
  tmp=$(mktemp)
  echo "$STATE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

is_dismissed() {
  local body_hash="$1"
  echo "$STATE" | jq -e --arg h "$body_hash" \
    '.dismissed_comments | map(.body_hash) | index($h) != null' > /dev/null 2>&1
}

add_dismissed() {
  local body_hash="$1" body_preview="$2" round="$3"
  STATE=$(echo "$STATE" | jq \
    --arg h "$body_hash" \
    --arg p "$body_preview" \
    --argjson r "$round" \
    '.dismissed_comments += [{"body_hash": $h, "body_preview": $p, "round": $r}]')
}

record_round() {
  local round="$1" review_id="$2" new_count="$3" fixed_count="$4" dismissed_count="$5"
  STATE=$(echo "$STATE" | jq \
    --argjson r "$round" \
    --argjson rid "$review_id" \
    --argjson n "$new_count" \
    --argjson f "$fixed_count" \
    --argjson d "$dismissed_count" \
    --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.rounds += [{"round": $r, "review_id": $rid, "new": $n, "fixed": $f, "dismissed": $d, "timestamp": $ts}]')
}

# ── Copilot Interaction ──────────────────────────────────────────────────────

# Get the PR's current HEAD commit SHA.
get_pr_head_sha() {
  gh api "repos/${REPO}/pulls/${PR_NUMBER}" --jq '.head.sha'
}

# Get the latest Copilot review as JSON with id and commit_id fields.
# Outputs "null" if no Copilot review exists.
get_latest_copilot_review() {
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews" \
    --jq '[.[] | select(.user.login | test("copilot"; "i"))] | last // null | {id, commit_id}'
}

# Check if a Copilot review is already pending (requested but not yet submitted).
is_copilot_review_pending() {
  local requested
  requested=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" \
    --jq '[.users[]? | select(.login | test("copilot"; "i"))] | length' 2>/dev/null || echo "0")
  [[ "$requested" -gt 0 ]]
}

# Request a Copilot review. Returns 0 on success, 1 on failure.
request_copilot_review() {
  local response
  if ! response=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" \
    --method POST -f 'reviewers[]=copilot' 2>&1); then
    log_warn "Failed to request Copilot review: ${response}"
    return 1
  fi
  return 0
}

# Get a Copilot review for the current HEAD. If one already exists, returns it
# immediately. Otherwise requests a review, polls until it appears, and returns
# it. Prints the review ID to stdout. Returns 1 if Copilot is unavailable or
# the poll times out.
# All log output goes to stderr so it doesn't contaminate the captured ID.
get_copilot_review_for_head() {
  local head_sha
  head_sha=$(get_pr_head_sha) || { echo "0"; return 1; }

  # Check if Copilot has already reviewed the current HEAD
  local latest_review latest_id latest_commit
  latest_review=$(get_latest_copilot_review 2>/dev/null || echo "null")
  latest_id=$(echo "$latest_review" | jq -r '.id // 0')
  latest_commit=$(echo "$latest_review" | jq -r '.commit_id // ""')

  if [[ "$latest_id" != "0" && "$latest_commit" == "$head_sha" ]]; then
    log_info "Copilot already reviewed current HEAD (${head_sha:0:7})" >&2
    echo "$latest_id"
    return 0
  fi

  # Check if a review is already pending, otherwise request one
  if is_copilot_review_pending; then
    log_info "Copilot review already pending — waiting for it to complete" >&2
  else
    log_info "Requesting Copilot review for HEAD ${head_sha:0:7}..." >&2
    if ! request_copilot_review; then
      # If the request failed and there are no prior reviews, Copilot isn't available
      if [[ "$latest_id" == "0" ]]; then
        return 1
      fi
    fi

    # Verify the request took effect (Copilot is now pending or has prior reviews)
    if ! is_copilot_review_pending && [[ "$latest_id" == "0" ]]; then
      return 1
    fi
  fi

  # Poll until a review for the current HEAD appears
  local elapsed=0
  while [[ $elapsed -lt $POLL_TIMEOUT ]]; do
    sleep "$POLL_INTERVAL"
    elapsed=$((elapsed + POLL_INTERVAL))

    latest_review=$(get_latest_copilot_review 2>/dev/null || echo "null")
    latest_id=$(echo "$latest_review" | jq -r '.id // 0')
    latest_commit=$(echo "$latest_review" | jq -r '.commit_id // ""')

    if [[ "$latest_id" != "0" && "$latest_commit" == "$head_sha" ]]; then
      echo "$latest_id"
      return 0
    fi

    log_info "Waiting for Copilot review... (${elapsed}s / ${POLL_TIMEOUT}s)" >&2
  done

  return 1
}

fetch_review_comments() {
  local review_id="$1"
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${review_id}/comments" \
    --jq '[.[] | {id, path, line, body, diff_hunk}]'
}

# ── Claude Prompt ────────────────────────────────────────────────────────────

build_prompt() {
  local comments_json="$1"
  local round="$2"

  cat <<PROMPT_EOF
You are reviewing Copilot's feedback on PR #${PR_NUMBER} in ${REPO} (round ${round}).

Below are Copilot's inline comments as JSON. For each comment, decide if it is
**legit** (the code genuinely should change) or **not-legit** (the code is fine,
or the suggestion is wrong/unhelpful).

## Instructions

For **legit** comments:
- Fix the code as suggested (or in a better way if the suggestion is suboptimal).
- If adding a clarifying code comment would help future readers, do so.

For **not-legit** comments:
- Reply to the comment explaining why you disagree. Use this exact command:
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments/{COMMENT_ID}/replies" --method POST -f body='Your reply here'
  Replace {COMMENT_ID} with the comment's "id" field from the JSON below.
- If the code could benefit from a clarifying comment to prevent future confusion,
  add one even though the code itself is correct.

After processing all comments:
1. Stage only the files you modified: git add <file1> <file2> ...
2. Commit: git commit -m "Address Copilot review feedback (round ${round})"
3. Push: git push

If you made no code changes (all comments were not-legit), skip the commit and push.

Finally, output a summary on the **very last line** of your response in exactly
this format (no markdown fencing, no extra whitespace on this line):
COPILOT_REVIEW_SUMMARY:{"fixed":[<list of comment IDs you fixed>],"dismissed":[<list of comment IDs you dismissed>],"errors":[<list of error descriptions, if any>]}

## Copilot Comments

${comments_json}
PROMPT_EOF
}

# Extract the JSON summary from Claude's output, stripping ANSI escape codes.
parse_summary() {
  local output="$1"
  local summary_line
  summary_line=$(echo "$output" \
    | sed $'s/\x1b\\[[0-9;]*m//g' \
    | grep 'COPILOT_REVIEW_SUMMARY:' \
    | tail -1)
  if [[ -n "$summary_line" ]]; then
    echo "${summary_line#*COPILOT_REVIEW_SUMMARY:}"
  else
    echo '{"fixed":[],"dismissed":[],"errors":["Could not parse summary from Claude output"]}'
  fi
}

# ── Argument Parsing ─────────────────────────────────────────────────────────

PR_URL=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --max-rounds)
      if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        log_error "--max-rounds must be a positive integer"
        exit 1
      fi
      MAX_ROUNDS="$2"; shift 2
      ;;
    --max-budget)
      if [[ ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        log_error "--max-budget must be a valid number (e.g., 5.00)"
        exit 1
      fi
      MAX_BUDGET="$2"; shift 2
      ;;
    --timeout)
      if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        log_error "--timeout must be a positive integer"
        exit 1
      fi
      TIMEOUT="$2"; shift 2
      ;;
    --poll-interval)
      if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        log_error "--poll-interval must be a positive integer"
        exit 1
      fi
      POLL_INTERVAL="$2"; shift 2
      ;;
    --poll-timeout)
      if [[ ! "${2:-}" =~ ^[0-9]+$ ]]; then
        log_error "--poll-timeout must be a positive integer"
        exit 1
      fi
      POLL_TIMEOUT="$2"; shift 2
      ;;
    --dry-run)
      DRY_RUN=true; shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      log_error "Unknown option: $1"
      usage
      ;;
    *)
      if [[ -n "$PR_URL" ]]; then
        log_error "Unexpected argument: $1"
        usage
      fi
      PR_URL="$1"; shift
      ;;
  esac
done

if [[ -z "$PR_URL" ]]; then
  log_error "PR URL is required. Run '$(basename "$0") --help' for usage."
  exit 1
fi

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
  if ! command -v claude &> /dev/null; then
    log_error "Claude CLI not found. Install it first."
    exit 1
  fi

  if ! command -v gh &> /dev/null; then
    log_error "GitHub CLI (gh) not found. Install it first."
    exit 1
  fi

  if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install it: brew install jq"
    exit 1
  fi

  if ! command -v timeout &> /dev/null; then
    log_error "timeout command not found. Install coreutils: brew install coreutils"
    exit 1
  fi

  if ! gh auth status &> /dev/null; then
    log_error "Not authenticated with GitHub. Run 'gh auth login' first."
    exit 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_prerequisites

  if ! parse_pr_url "$PR_URL"; then
    log_error "Invalid GitHub PR URL: ${PR_URL}"
    log_error "Expected format: https://github.com/owner/repo/pull/123"
    exit 1
  fi

  validate_working_directory "$REPO"
  load_state

  TMPDIR_LOOP=$(mktemp -d)
  trap 'save_state; rm -rf "$TMPDIR_LOOP"' EXIT

  log_info "Starting Copilot review loop for ${REPO}#${PR_NUMBER}"
  log_info "Max rounds: ${MAX_ROUNDS}, Budget per round: \$${MAX_BUDGET}, Timeout: ${TIMEOUT}s"

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Running in DRY RUN mode"
  fi

  local total_fixed=0
  local total_dismissed=0

  for ((round = 1; round <= MAX_ROUNDS; round++)); do
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Round ${round}/${MAX_ROUNDS}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    if [[ "$DRY_RUN" == "true" ]]; then
      if is_copilot_review_pending; then
        log_info "[DRY RUN] Copilot review already pending — would wait for it"
      else
        log_info "[DRY RUN] Would request Copilot review on ${REPO}#${PR_NUMBER}"
      fi
      log_info "[DRY RUN] Would poll for review matching current HEAD (interval: ${POLL_INTERVAL}s, timeout: ${POLL_TIMEOUT}s)"
      break
    fi

    # Get a Copilot review for the current HEAD (reuses existing if available)
    local review_id
    review_id=$(get_copilot_review_for_head) || {
      if [[ "$review_id" == "0" ]]; then
        log_error "Copilot does not appear to be enabled for ${REPO}."
        log_error "Enable Copilot code review in the repository settings first."
      else
        log_error "Copilot review did not appear within ${POLL_TIMEOUT}s"
      fi
      break
    }
    log_success "Copilot review: ${review_id}"

    # Fetch inline comments for the new review
    local comments
    comments=$(fetch_review_comments "$review_id")
    local comment_count
    comment_count=$(echo "$comments" | jq 'length')
    log_info "Fetched ${comment_count} comment(s)"

    if [[ "$comment_count" -eq 0 ]]; then
      log_success "No comments from Copilot — PR looks clean!"
      record_round "$round" "$review_id" 0 0 0
      break
    fi

    # Filter out comments whose body hash matches a previously dismissed one
    local new_comments="[]"
    local skipped=0
    while IFS= read -r comment; do
      local body body_hash
      body=$(echo "$comment" | jq -r '.body')
      body_hash=$(hash_comment "$body")
      if is_dismissed "$body_hash"; then
        ((skipped++)) || true
      else
        new_comments=$(echo "$new_comments" | jq --argjson c "$comment" '. += [$c]')
      fi
    done < <(echo "$comments" | jq -c '.[]')

    local new_count
    new_count=$(echo "$new_comments" | jq 'length')

    if [[ $skipped -gt 0 ]]; then
      log_info "Filtered out ${skipped} previously dismissed comment(s)"
    fi

    if [[ "$new_count" -eq 0 ]]; then
      log_success "All ${comment_count} comment(s) were previously dismissed — done!"
      record_round "$round" "$review_id" 0 0 0
      break
    fi

    log_info "${new_count} new comment(s) to evaluate"

    # Build prompt and invoke Claude
    local prompt
    prompt=$(build_prompt "$(echo "$new_comments" | jq '.')" "$round")

    log_info "Invoking Claude (budget: \$${MAX_BUDGET}, timeout: ${TIMEOUT}s)..."

    local output_file exit_code=0
    output_file="${TMPDIR_LOOP}/claude-output-round-${round}.txt"
    timeout "$TIMEOUT" claude -p --max-budget-usd "$MAX_BUDGET" "$prompt" 2>&1 \
      | tee "$output_file" \
      || exit_code=$?

    if [[ $exit_code -eq 124 ]]; then
      log_error "Claude timed out after ${TIMEOUT}s"
      rm -f "$output_file"
      record_round "$round" "$review_id" "$new_count" 0 0
      break
    elif [[ $exit_code -ne 0 ]]; then
      log_error "Claude exited with code ${exit_code}"
      rm -f "$output_file"
      record_round "$round" "$review_id" "$new_count" 0 0
      break
    fi

    # Parse Claude's summary output
    local output summary
    output=$(cat "$output_file")
    rm -f "$output_file"

    summary=$(parse_summary "$output")
    local fixed_count dismissed_count error_count
    fixed_count=$(echo "$summary" | jq '.fixed // [] | length')
    dismissed_count=$(echo "$summary" | jq '.dismissed // [] | length')
    error_count=$(echo "$summary" | jq '.errors // [] | length')

    log_info "Round ${round} results: ${fixed_count} fixed, ${dismissed_count} dismissed, ${error_count} error(s)"

    total_fixed=$((total_fixed + fixed_count))
    total_dismissed=$((total_dismissed + dismissed_count))

    # Record newly dismissed comments in state so they're filtered in future rounds
    while IFS= read -r dismissed_id; do
      local body body_hash body_preview
      body=$(echo "$new_comments" | jq -r --argjson id "$dismissed_id" \
        '.[] | select(.id == $id) | .body')
      if [[ -n "$body" ]]; then
        body_hash=$(hash_comment "$body")
        body_preview=$(echo "$body" | head -c 80)
        add_dismissed "$body_hash" "$body_preview" "$round"
      fi
    done < <(echo "$summary" | jq -r '.dismissed // [] | .[]')

    record_round "$round" "$review_id" "$new_count" "$fixed_count" "$dismissed_count"
    save_state

    if [[ $error_count -gt 0 ]]; then
      log_warn "Errors encountered in round ${round} — stopping"
      break
    fi

    log_success "Round ${round} complete"
  done

  # Print summary
  echo ""
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  if [[ "$DRY_RUN" == "true" ]]; then
    log_info "[DRY RUN] Copilot Review Loop Complete"
  else
    log_info "Copilot Review Loop Complete"
  fi
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "PR: ${REPO}#${PR_NUMBER}"
  if [[ "$DRY_RUN" != "true" ]]; then
    log_info "Total fixed: ${total_fixed}"
    log_info "Total dismissed: ${total_dismissed}"
    log_info "Rounds completed: $(echo "$STATE" | jq '.rounds | length')"
    log_info "State saved to: ${STATE_FILE}"
  fi
}

main "$@"
