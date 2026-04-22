#!/usr/bin/env bash
# go-loop.sh - Outer convergence loop for the /go skill
#
# Alternates review-fix-loop.sh (Claude) and copilot-review-loop.sh (Copilot)
# until a full cycle produces zero fixes from both, or --max-cycles is hit.
#
# Usage:
#   go-loop.sh [OPTIONS]
#
# Must be run from a git repository on a branch that has been pushed.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/github.sh"

# ── Configuration Defaults ───────────────────────────────────────────────────

MAX_CYCLES=3
SKIP_COPILOT=false

REVIEW_FIX_LOOP="${SCRIPT_DIR}/review-fix-loop.sh"
COPILOT_REVIEW_LOOP="${SCRIPT_DIR}/copilot-review-loop.sh"

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
  local code="${1:-0}"
  local stream=1
  [[ "$code" -ne 0 ]] && stream=2
  cat >&"$stream" <<EOF
Usage: $(basename "$0") [OPTIONS]

Outer convergence loop for /go. Alternates Claude and Copilot review loops
until a full cycle produces zero fixes from both reviewers, or --max-cycles
is hit.

Options:
  --max-cycles N     Maximum outer cycles (default: 3)
  --skip-copilot     Run only the Claude review loop
  -h, --help         Show this help message

Outputs:
  .notes/go-summary.json  Summary of cycles and fixes per reviewer

Exit codes:
  0  Converged (both reviewers returned 0 fixes in the last cycle)
  1  Hit --max-cycles without converging, or an inner loop failed
EOF
  exit "$code"
}

# ── Argument Parsing ─────────────────────────────────────────────────────────

while [[ $# -gt 0 ]]; do
  case $1 in
    --max-cycles)
      if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "--max-cycles must be a positive integer"
        exit 1
      fi
      MAX_CYCLES="$2"; shift 2
      ;;
    --skip-copilot)
      SKIP_COPILOT=true; shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      log_error "Unknown option: $1"
      usage 1
      ;;
  esac
done

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
  if ! command -v jq &> /dev/null; then
    log_error "jq not found. Install it: brew install jq"
    exit 1
  fi

  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    log_error "Not in a git repository."
    exit 1
  fi

  if [[ ! -x "$REVIEW_FIX_LOOP" ]]; then
    log_error "review-fix-loop.sh not found or not executable at: $REVIEW_FIX_LOOP"
    exit 1
  fi

  if [[ "$SKIP_COPILOT" != "true" && ! -x "$COPILOT_REVIEW_LOOP" ]]; then
    log_error "copilot-review-loop.sh not found or not executable at: $COPILOT_REVIEW_LOOP"
    log_error "Pass --skip-copilot to run only the Claude review loop."
    exit 1
  fi
}

# ── Reviewer wrappers ────────────────────────────────────────────────────────

# Path to the Copilot loop's per-PR state file. Mirrors the layout encoded in
# copilot-review-loop.sh; if that layout ever changes, update both.
copilot_state_file() {
  echo "${HOME}/.local/state/copilot-review-loop/${OWNER}-${REPO_NAME}-${PR_NUMBER}.json"
}

run_claude_loop() {
  local repo_root status_file
  repo_root=$(git rev-parse --show-toplevel)
  status_file="${repo_root}/.notes/review-cycle-status.json"
  rm -f "$status_file"

  log_info "Running Claude review loop…"
  if ! "$REVIEW_FIX_LOOP"; then
    # review-fix-loop.sh returns non-zero both for hard failures and for
    # "findings remain after max-iterations". Distinguish by whether the
    # status file was written.
    log_warn "review-fix-loop.sh exited non-zero (findings may remain)"
  fi

  if [[ ! -f "$status_file" ]]; then
    log_error "review-fix-loop.sh did not produce a status file"
    return 1
  fi

  local fixed
  fixed=$(jq -r '.fixed // 0' "$status_file")
  if [[ ! "$fixed" =~ ^[0-9]+$ ]]; then
    log_error "review-fix-loop.sh status file has invalid 'fixed' value"
    return 1
  fi
  echo "$fixed"
}

run_copilot_loop() {
  if [[ -z "${PR_NUMBER:-}" ]]; then
    log_warn "No PR found for current branch — skipping Copilot round"
    echo "0"
    return 0
  fi

  local state_file
  state_file=$(copilot_state_file)

  local rounds_before=0
  if [[ -f "$state_file" ]]; then
    rounds_before=$(jq -r '.rounds | length' "$state_file")
  fi

  log_info "Running Copilot review loop for PR #${PR_NUMBER}…"
  "$COPILOT_REVIEW_LOOP" "$PR_NUMBER" || \
    log_warn "copilot-review-loop.sh exited non-zero"

  if [[ ! -f "$state_file" ]]; then
    # Loop never completed a round (e.g. pending-push detection aborted it).
    echo "0"
    return 0
  fi

  local fixed
  fixed=$(jq -r --argjson before "$rounds_before" \
    '[.rounds[$before:] // [] | .[].fixed] | add // 0' "$state_file")
  if [[ ! "$fixed" =~ ^[0-9]+$ ]]; then
    log_error "copilot-review-loop.sh state file has invalid 'fixed' values"
    return 1
  fi
  echo "$fixed"
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_prerequisites

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)
  mkdir -p "${repo_root}/.notes"
  local summary_file="${repo_root}/.notes/go-summary.json"
  local branch
  branch=$(git branch --show-current)

  # Resolve the PR for the current branch once so run_copilot_loop doesn't
  # re-query gh per cycle. When --skip-copilot is set, a missing PR is fine.
  OWNER=""; REPO_NAME=""; REPO=""; PR_NUMBER=""
  if [[ "$SKIP_COPILOT" != "true" ]]; then
    if ! resolve_pr_target ""; then
      log_warn "Could not resolve a PR for the current branch — continuing with Copilot disabled"
      SKIP_COPILOT=true
    fi
  fi

  local claude_fixes=()
  local copilot_fixes=()
  local converged=false
  local cycle=0

  log_info "Starting /go outer loop (max cycles: ${MAX_CYCLES}, skip Copilot: ${SKIP_COPILOT})"

  for ((cycle = 1; cycle <= MAX_CYCLES; cycle++)); do
    log_section "Cycle ${cycle}/${MAX_CYCLES}"

    local c_fixes p_fixes
    if ! c_fixes=$(run_claude_loop); then
      log_error "Claude loop failed in cycle ${cycle} — aborting"
      break
    fi
    claude_fixes+=("$c_fixes")
    log_info "Claude fixes this cycle: ${c_fixes}"

    if [[ "$SKIP_COPILOT" == "true" ]]; then
      p_fixes=0
    else
      if ! p_fixes=$(run_copilot_loop); then
        log_error "Copilot loop failed in cycle ${cycle} — aborting"
        break
      fi
    fi
    copilot_fixes+=("$p_fixes")
    log_info "Copilot fixes this cycle: ${p_fixes}"

    if [[ "$c_fixes" -eq 0 && "$p_fixes" -eq 0 ]]; then
      converged=true
      log_success "Both reviewers returned 0 fixes — converged!"
      break
    fi
  done
  local cycles_run=$((cycle > MAX_CYCLES ? MAX_CYCLES : cycle))

  local pr_url=""
  if [[ -n "$PR_NUMBER" ]]; then
    pr_url=$(gh pr view "$PR_NUMBER" --json url -q '.url' 2>/dev/null || true)
  fi

  local claude_json copilot_json
  claude_json=$(jq -cn '$ARGS.positional | map(tonumber)' --args "${claude_fixes[@]}")
  copilot_json=$(jq -cn '$ARGS.positional | map(tonumber)' --args "${copilot_fixes[@]}")

  jq -n \
    --argjson cycles "$cycles_run" \
    --argjson max "$MAX_CYCLES" \
    --argjson converged "$converged" \
    --argjson claude_fixes "$claude_json" \
    --argjson copilot_fixes "$copilot_json" \
    --arg pr_url "$pr_url" \
    --arg branch "$branch" \
    --arg skip_copilot "$SKIP_COPILOT" \
    '{
       cycles: $cycles,
       max_cycles: $max,
       converged: $converged,
       claude_fixes: $claude_fixes,
       copilot_fixes: $copilot_fixes,
       pr_url: $pr_url,
       branch: $branch,
       skip_copilot: ($skip_copilot == "true")
     }' > "$summary_file"

  log_section "/go Loop Complete"
  log_info "Cycles: ${cycles_run}/${MAX_CYCLES}"
  log_info "Claude fixes per cycle: ${claude_fixes[*]:-(none)}"
  log_info "Copilot fixes per cycle: ${copilot_fixes[*]:-(none)}"
  if [[ -n "$pr_url" ]]; then
    log_info "PR: ${pr_url}"
  fi
  log_info "Summary: ${summary_file}"

  if [[ "$converged" == "true" ]]; then
    log_success "Converged"
    return 0
  fi
  log_warn "Did not converge within ${MAX_CYCLES} cycles"
  return 1
}

main "$@"
