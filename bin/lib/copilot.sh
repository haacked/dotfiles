#!/usr/bin/env bash
# copilot.sh - Shared Copilot GitHub API helpers
#
# Source this file to interact with GitHub Copilot's pull request reviewer:
#   source "${SCRIPT_DIR}/lib/copilot.sh"
#
# Expects the caller to set these globals:
#   REPO        - "owner/repo" (e.g. "PostHog/posthog")
#   PR_NUMBER   - PR number (e.g. "123")
#
# Functions:
#   hash_comment              - SHA-256 hash of a normalized comment body
#   get_pr_head_sha           - Current HEAD SHA of the PR
#   get_latest_copilot_review - Latest Copilot review as JSON {id, commit_id}
#   is_copilot_review_pending - True if a Copilot review is requested but not submitted
#   request_copilot_review    - Request a Copilot review on the PR
#   get_copilot_review_for_head - Get or request+poll a review for the current HEAD
#   fetch_review_comments     - Fetch inline comments for a given review ID

# The short name "copilot" silently no-ops on the requested_reviewers endpoint.
# The full bot login is required to actually trigger a review.
COPILOT_REVIEWER="copilot-pull-request-reviewer[bot]"

# Compute SHA-256 hash of a normalized (trimmed, lowercased) comment body.
# Prefers sha256sum (Linux) with fallback to shasum -a 256 (macOS).
hash_comment() {
  local body="$1"
  local hash_cmd
  if command -v sha256sum &>/dev/null; then
    hash_cmd="sha256sum"
  else
    hash_cmd="shasum -a 256"
  fi
  echo -n "$body" \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' \
    | $hash_cmd \
    | cut -d' ' -f1
}

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
    --method POST -f "reviewers[]=${COPILOT_REVIEWER}" 2>&1); then
    log_warn "Failed to request Copilot review: ${response}"
    return 1
  fi
  return 0
}

# Get a Copilot review for the current HEAD. If one already exists, returns it
# immediately. Otherwise requests a review, polls until it appears, and returns
# it. Prints the review ID to stdout.
# Returns 1 on poll timeout, 2 if Copilot is not enabled for the repo.
# All log output goes to stderr so it doesn't contaminate the captured ID.
#
# Callers can override polling behavior via POLL_INTERVAL (default 15) and
# POLL_TIMEOUT (default 600).
get_copilot_review_for_head() {
  local poll_interval="${POLL_INTERVAL:-15}"
  local poll_timeout="${POLL_TIMEOUT:-600}"

  local head_sha
  head_sha=$(get_pr_head_sha) || return 1

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
      if [[ "$latest_id" == "0" ]]; then
        log_error "Copilot does not appear to be enabled for ${REPO}." >&2
        log_error "Enable Copilot code review in the repository settings first." >&2
        return 2
      fi
    fi

    if ! is_copilot_review_pending && [[ "$latest_id" == "0" ]]; then
      log_error "Copilot does not appear to be enabled for ${REPO}." >&2
      log_error "Enable Copilot code review in the repository settings first." >&2
      return 2
    fi
  fi

  # Poll until a review for the current HEAD appears
  local elapsed=0
  while [[ $elapsed -lt $poll_timeout ]]; do
    sleep "$poll_interval"
    elapsed=$((elapsed + poll_interval))

    latest_review=$(get_latest_copilot_review 2>/dev/null || echo "null")
    latest_id=$(echo "$latest_review" | jq -r '.id // 0')
    latest_commit=$(echo "$latest_review" | jq -r '.commit_id // ""')

    if [[ "$latest_id" != "0" && "$latest_commit" == "$head_sha" ]]; then
      echo "$latest_id"
      return 0
    fi

    log_info "Waiting for Copilot review... (${elapsed}s / ${poll_timeout}s)" >&2
  done

  log_error "Copilot review did not appear within ${poll_timeout}s" >&2
  return 1
}

# Fetch inline comments for a review, returning JSON array of {id, path, line, body, diff_hunk}.
fetch_review_comments() {
  local review_id="$1"
  gh api "repos/${REPO}/pulls/${PR_NUMBER}/reviews/${review_id}/comments" \
    --jq '[.[] | {id, path, line, body, diff_hunk}]'
}
