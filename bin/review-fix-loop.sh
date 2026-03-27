#!/usr/bin/env bash
# review-fix-loop.sh - Automated review-fix-simplify-commit cycle
#
# Runs `/review-fix-cycle` in a loop with fresh Claude context per iteration.
# Stops when the review comes back clean or max iterations are reached.
#
# Usage:
#   review-fix-loop.sh [<review-target>] [OPTIONS]
#
# Must be run from within a git repository.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# ── Configuration Defaults ───────────────────────────────────────────────────

MAX_ITERATIONS=3
MAX_BUDGET="5.00"
TIMEOUT=600
DRY_RUN=false

# ── Usage ────────────────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") [<review-target>] [OPTIONS]

Automated review-fix-simplify-commit cycle. Invokes /review-fix-cycle with
fresh Claude context per iteration. Stops when the review is clean or max
iterations are reached.

Must be run from within a git repository.

Arguments:
  <review-target>       Anything /review-code accepts: PR URL, PR number,
                        branch name, commit, range. If omitted, auto-detects
                        PR or current branch.

Options:
  --max-iterations N    Max review-fix cycles (default: 3)
  --max-budget USD      Claude budget per iteration in USD (default: 5.00)
  --timeout SECONDS     Claude timeout per iteration (default: 600)
  --dry-run             Show what would happen without executing
  -h, --help            Show this help message

Examples:
  $(basename "$0")                                # Auto-detect PR or branch
  $(basename "$0") feature-branch                 # Review specific branch
  $(basename "$0") https://github.com/o/r/pull/1  # Review specific PR
  $(basename "$0") --max-iterations 5             # Up to 5 iterations
  $(basename "$0") --dry-run                      # Preview without running
EOF
  exit "${1:-0}"
}

# ── Argument Parsing ─────────────────────────────────────────────────────────

REVIEW_TARGET=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --max-iterations)
      if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "--max-iterations must be a positive integer"
        exit 1
      fi
      MAX_ITERATIONS="$2"; shift 2
      ;;
    --max-budget)
      if [[ ! "${2:-}" =~ ^[0-9]+(\.[0-9]+)?$ ]] || [[ "${2:-}" =~ ^0+(\.0+)?$ ]]; then
        log_error "--max-budget must be a positive number (e.g., 5.00)"
        exit 1
      fi
      MAX_BUDGET="$2"; shift 2
      ;;
    --timeout)
      if [[ ! "${2:-}" =~ ^[1-9][0-9]*$ ]]; then
        log_error "--timeout must be a positive integer"
        exit 1
      fi
      TIMEOUT="$2"; shift 2
      ;;
    --dry-run)
      DRY_RUN=true; shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      log_error "Unknown option: $1"
      usage 1
      ;;
    *)
      if [[ -n "$REVIEW_TARGET" ]]; then
        log_error "Unexpected argument: $1"
        usage 1
      fi
      REVIEW_TARGET="$1"; shift
      ;;
  esac
done

# ── Prerequisites ────────────────────────────────────────────────────────────

check_prerequisites() {
  if ! command -v claude &> /dev/null; then
    log_error "Claude CLI not found. Install it first."
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

  if ! git rev-parse --git-dir > /dev/null 2>&1; then
    log_error "Not in a git repository."
    exit 1
  fi

  if [[ ! -d "$HOME/.claude/skills/review-code" ]]; then
    log_error "review-code skill not found. Install it first."
    exit 1
  fi
}

# ── Main ─────────────────────────────────────────────────────────────────────

main() {
  check_prerequisites

  local repo_root
  repo_root=$(git rev-parse --show-toplevel)
  local status_file="${repo_root}/.notes/review-cycle-status.json"

  # Ensure .notes directory exists
  mkdir -p "${repo_root}/.notes"

  local tmpdir
  tmpdir=$(mktemp -d)
  trap 'rm -rf "$tmpdir"' EXIT

  log_info "Starting review-fix loop"
  log_info "Max iterations: ${MAX_ITERATIONS}, Budget per iteration: \$${MAX_BUDGET}, Timeout: ${TIMEOUT}s"
  if [[ -n "$REVIEW_TARGET" ]]; then
    log_info "Review target: ${REVIEW_TARGET}"
  else
    log_info "Review target: auto-detect"
  fi

  if [[ "$DRY_RUN" == "true" ]]; then
    log_warn "Running in DRY RUN mode"
    log_info "Would run: claude -p --dangerously-skip-permissions --verbose --max-budget-usd ${MAX_BUDGET}"
    log_info "Prompt: /review-fix-cycle ${REVIEW_TARGET} --iteration 1"
    log_info "Up to ${MAX_ITERATIONS} iterations"
    return 0
  fi

  local total_fixed=0
  local total_skipped=0
  local last_iteration=0
  local loop_failed=false

  for ((iteration = 1; iteration <= MAX_ITERATIONS; iteration++)); do
    last_iteration=$iteration
    echo ""
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    log_info "Iteration ${iteration}/${MAX_ITERATIONS}"
    log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Remove status file so we can detect if the skill wrote a new one
    rm -f "$status_file"

    local output_file="${tmpdir}/claude-output-iteration-${iteration}.txt"
    local prompt="/review-fix-cycle${REVIEW_TARGET:+ $REVIEW_TARGET} --iteration ${iteration}"

    log_info "Invoking Claude (budget: \$${MAX_BUDGET}, timeout: ${TIMEOUT}s)..."

    # Write prompt to file to avoid shell argument length limits
    local prompt_file="${tmpdir}/prompt-iteration-${iteration}.txt"
    printf '%s' "$prompt" > "$prompt_file"

    local exit_code
    # Needs broad tool access: chains /review-code, /simplify, and /commit sub-skills
    set +eo pipefail
    timeout "$TIMEOUT" claude -p \
      --dangerously-skip-permissions \
      --verbose \
      --max-budget-usd "$MAX_BUDGET" \
      < "$prompt_file" 2>&1 \
      | tee "$output_file"
    exit_code=${PIPESTATUS[0]}
    set -eo pipefail

    # Only persist output to .notes/ on failure so error messages can reference it
    local log_file="${repo_root}/.notes/claude-output-iteration-${iteration}.log"

    if [[ $exit_code -eq 124 ]]; then
      cp "$output_file" "$log_file"
      log_error "Claude timed out after ${TIMEOUT}s"
      log_error "Check output: ${log_file}"
      loop_failed=true
      break
    elif [[ $exit_code -ne 0 ]]; then
      cp "$output_file" "$log_file"
      log_error "Claude exited with code ${exit_code}"
      log_error "Check output: ${log_file}"
      loop_failed=true
      break
    fi

    # Parse status file (handles missing file and corrupt JSON in one shot)
    local clean fixed skipped
    if ! read -r clean fixed skipped < <(
      jq -r '[.clean // false, .fixed // 0, .skipped // 0] | @tsv' "$status_file" 2>/dev/null
    ); then
      cp "$output_file" "$log_file"
      log_error "No valid status file after iteration ${iteration}"
      log_error "Check output: ${log_file}"
      loop_failed=true
      break
    fi

    total_fixed=$((total_fixed + fixed))
    total_skipped=$((total_skipped + skipped))

    log_info "Fixed: ${fixed}, Skipped: ${skipped}"

    if [[ "$clean" = "true" ]]; then
      log_success "Review came back clean — done!"
      break
    fi

    log_success "Iteration ${iteration} complete"
  done

  # Print summary
  echo ""
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "Review-Fix Loop Complete"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

  local final_status="Unknown"
  if [[ -f "$status_file" ]]; then
    local final_clean
    final_clean=$(jq -r '.clean' "$status_file")
    if [[ "$final_clean" = "true" ]]; then
      final_status="Clean"
    else
      final_status="Findings remain"
    fi
  fi

  log_info "Iterations: ${last_iteration}/${MAX_ITERATIONS}"
  log_info "Total fixed: ${total_fixed}"
  log_info "Total skipped: ${total_skipped}"
  log_info "Status: ${final_status}"

  local skipped_file="${repo_root}/.notes/review-skipped.md"
  if [[ -f "$skipped_file" ]]; then
    log_info "Skipped items: ${skipped_file}"
  fi

  if [[ "$loop_failed" == "true" ]]; then
    return 1
  fi

  if [[ "$final_status" != "Clean" ]]; then
    return 1
  fi
}

main "$@"
