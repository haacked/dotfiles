#!/usr/bin/env bash
# logging.sh - Shared logging utilities for bash scripts
#
# Source this file to get colored logging functions:
#   source "${SCRIPT_DIR}/lib/logging.sh"
#
# Functions:
#   log_info    - Blue [INFO] prefix
#   log_success - Green [SUCCESS] prefix
#   log_warn    - Yellow [WARN] prefix
#   log_error   - Red [ERROR] prefix (outputs to stderr)
#   log_section - Prints a titled section divider

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
DIM='\033[2m'
NC='\033[0m' # No Color

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

log_section() {
  echo ""
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  log_info "$1"
  log_info "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

# ── Heartbeat ──────────────────────────────────────────────────────────────

# Global PID for the heartbeat background process
_HEARTBEAT_PID=""

# Start a background heartbeat that prints elapsed time to stderr every N seconds.
# IMPORTANT: Must be called from the main shell, not from a subshell or pipeline.
# If called inside $(...) or a pipe, _HEARTBEAT_PID won't propagate and the
# process will leak.
# Usage: start_heartbeat [interval_seconds] [label]
start_heartbeat() {
  local interval="${1:-30}"
  local label="${2:-Working}"
  stop_heartbeat
  (
    exec >/dev/null  # close stdout so we don't hold pipes open
    trap 'exit 0' TERM
    local start_time=$SECONDS
    while true; do
      # Background sleep + wait so TERM interrupts immediately
      sleep "$interval" &
      wait $! 2>/dev/null || exit 0
      local elapsed=$((SECONDS - start_time))
      local mins=$((elapsed / 60))
      local secs=$((elapsed % 60))
      printf '%b[HEARTBEAT] %s… %dm %02ds elapsed%b\n' "$DIM" "$label" "$mins" "$secs" "$NC" >&2
    done
  ) &
  _HEARTBEAT_PID=$!
}

# Stop the heartbeat background process. Safe to call when none is running.
stop_heartbeat() {
  if [[ -n "${_HEARTBEAT_PID:-}" ]]; then
    kill "$_HEARTBEAT_PID" 2>/dev/null || true
    wait "$_HEARTBEAT_PID" 2>/dev/null || true
    _HEARTBEAT_PID=""
  fi
}
