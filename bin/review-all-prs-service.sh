#!/usr/bin/env bash
# review-all-prs-service.sh - Manage the review-all-prs LaunchAgent
#
# Usage:
#   review-all-prs-service.sh [install|uninstall|start|stop|status|logs|run]
#
# Commands:
#   install    Create symlink and load the agent
#   uninstall  Unload the agent and remove symlink
#   start      Manually trigger the review job now
#   stop       Unload the agent (disable scheduled runs)
#   status     Show agent status
#   logs       Tail the log file
#   run        Run the review script manually (for testing)

set -euo pipefail

PLIST_NAME="com.haacked.review-all-prs.plist"
PLIST_SOURCE="${HOME}/.dotfiles/macos/LaunchAgents/${PLIST_NAME}"
PLIST_DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
STATE_DIR="${HOME}/.local/state/review-all-prs"
LOG_FILE="${STATE_DIR}/launchd.log"
LABEL="com.haacked.review-all-prs"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Manage the review-all-prs LaunchAgent.

Commands:
  install    Create symlink and load the agent
  uninstall  Unload the agent and remove symlink
  start      Manually trigger the review job now
  stop       Unload the agent (disable scheduled runs)
  status     Show agent status
  logs       Tail the log file
  run        Run the review script manually (for testing)

Examples:
  $(basename "$0") install    # Set up scheduled reviews
  $(basename "$0") start      # Run reviews now
  $(basename "$0") logs       # Watch the log output
  $(basename "$0") status     # Check if agent is loaded
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

cmd_install() {
  log_info "Installing review-all-prs LaunchAgent..."

  # Ensure state directory exists
  mkdir -p "$STATE_DIR"

  # Check if source plist exists
  if [[ ! -f "$PLIST_SOURCE" ]]; then
    log_error "Source plist not found: $PLIST_SOURCE"
    exit 1
  fi

  # Create symlink
  if [[ -L "$PLIST_DEST" ]]; then
    log_warn "Symlink already exists, recreating..."
    rm "$PLIST_DEST"
  elif [[ -f "$PLIST_DEST" ]]; then
    log_error "Regular file exists at $PLIST_DEST - remove it first"
    exit 1
  fi

  ln -s "$PLIST_SOURCE" "$PLIST_DEST"
  log_info "Created symlink: $PLIST_DEST -> $PLIST_SOURCE"

  # Load the agent
  if launchctl list | grep -q "$LABEL"; then
    log_warn "Agent already loaded, reloading..."
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
  fi

  launchctl load "$PLIST_DEST"
  log_success "LaunchAgent installed and loaded"
  log_info "Reviews will run at 9am on weekdays"
  log_info "Use '$(basename "$0") start' to run immediately"
}

cmd_uninstall() {
  log_info "Uninstalling review-all-prs LaunchAgent..."

  # Unload if loaded
  if launchctl list | grep -q "$LABEL"; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    log_info "Agent unloaded"
  fi

  # Remove symlink
  if [[ -L "$PLIST_DEST" || -f "$PLIST_DEST" ]]; then
    rm "$PLIST_DEST"
    log_info "Removed: $PLIST_DEST"
  fi

  log_success "LaunchAgent uninstalled"
}

cmd_start() {
  log_info "Triggering review job..."

  if ! launchctl list | grep -q "$LABEL"; then
    log_error "Agent not loaded. Run 'install' first."
    exit 1
  fi

  launchctl start "$LABEL"
  log_success "Review job started"
  log_info "Use '$(basename "$0") logs' to watch progress"
}

cmd_stop() {
  log_info "Stopping LaunchAgent..."

  if launchctl list | grep -q "$LABEL"; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    log_success "Agent stopped (unloaded)"
  else
    log_warn "Agent was not loaded"
  fi
}

cmd_status() {
  echo "LaunchAgent Status:"
  echo "==================="

  if [[ -L "$PLIST_DEST" ]]; then
    echo -e "Symlink:  ${GREEN}installed${NC}"
  elif [[ -f "$PLIST_DEST" ]]; then
    echo -e "Symlink:  ${YELLOW}regular file (not symlink)${NC}"
  else
    echo -e "Symlink:  ${RED}not installed${NC}"
  fi

  if launchctl list | grep -q "$LABEL"; then
    echo -e "Agent:    ${GREEN}loaded${NC}"
    # Get last exit status
    local status
    status=$(launchctl list | grep "$LABEL" | awk '{print $1}')
    if [[ "$status" == "-" ]]; then
      echo "Last run: never (or running)"
    elif [[ "$status" == "0" ]]; then
      echo -e "Last run: ${GREEN}success (exit 0)${NC}"
    else
      echo -e "Last run: ${RED}failed (exit $status)${NC}"
    fi
  else
    echo -e "Agent:    ${RED}not loaded${NC}"
  fi

  if [[ -f "$LOG_FILE" ]]; then
    local log_size
    log_size=$(du -h "$LOG_FILE" | cut -f1)
    local log_lines
    log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    echo "Log file: $LOG_FILE ($log_size, $log_lines lines)"
  else
    echo "Log file: not created yet"
  fi

  # Show today's session if exists
  local today
  today=$(date +%Y-%m-%d)
  local session_file="${STATE_DIR}/session-${today}.json"
  if [[ -f "$session_file" ]]; then
    local reviewed
    reviewed=$(jq '.reviewed | length' < "$session_file")
    local failed
    failed=$(jq '.failed | length' < "$session_file")
    echo ""
    echo "Today's session:"
    echo "  Reviewed: $reviewed"
    echo "  Failed:   $failed"
  fi
}

cmd_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    log_warn "Log file doesn't exist yet: $LOG_FILE"
    log_info "Run 'start' to trigger a review and create logs"
    exit 0
  fi

  log_info "Tailing log file (Ctrl+C to stop)..."
  tail -f "$LOG_FILE"
}

cmd_run() {
  log_info "Running review script manually..."
  exec "${HOME}/.dotfiles/bin/run-pr-reviews.sh" --auto "$@"
}

# Main
if [[ $# -eq 0 ]]; then
  usage
fi

case "${1:-}" in
  install)
    cmd_install
    ;;
  uninstall)
    cmd_uninstall
    ;;
  start)
    cmd_start
    ;;
  stop)
    cmd_stop
    ;;
  status)
    cmd_status
    ;;
  logs)
    cmd_logs
    ;;
  run)
    shift
    cmd_run "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    log_error "Unknown command: $1"
    usage
    ;;
esac
