#!/usr/bin/env bash
# ops-report-service.sh - Manage the ops-report LaunchAgents (daily and weekly).
#
# Usage:
#   ops-report-service.sh <command> [daily|weekly]
#
# The optional second argument selects which agent to act on (default: daily).
#
# Commands:
#   install    Create symlink, log directory, and load the agent
#   uninstall  Unload the agent and remove symlink
#   start      Manually trigger the run now (via launchctl)
#   stop       Unload the agent (disable scheduled runs)
#   status     Show agent status and the last session ID
#   logs       Tail the launchd log file
#   run        Run the worker script directly in this terminal (for testing)
#   resume     Resume the most recent session (claude --resume <last-session-id>)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"

# Auto-detect the worktree/install root from this script's location, so `run`
# and `resume` work both from ~/.dotfiles (installed) and from a worktree.
# install/uninstall still pin to ~/.dotfiles since that's where the merged
# code lives and where the LaunchAgent symlink should point.
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
WORKER="${REPO_ROOT}/bin/ops-report-run"

# The report kind (daily|weekly) is the optional second positional argument and
# selects the agent, state dir, and worker window. One worker serves both.
KIND="${2:-daily}"
case "$KIND" in
  daily)  WINDOW="day";  SCHEDULE_DESC="Tue–Fri at 09:00 local time" ;;
  weekly) WINDOW="week"; SCHEDULE_DESC="Monday at 09:00 local time" ;;
  *)
    log_error "Unknown report kind: '$KIND' (expected 'daily' or 'weekly')"
    exit 64
    ;;
esac

PLIST_NAME="com.haacked.ops-report-${KIND}.plist"
PLIST_SOURCE="${HOME}/.dotfiles/macos/LaunchAgents/${PLIST_NAME}"
PLIST_DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
STATE_DIR="${HOME}/.local/state/ops-report-${KIND}"
LOG_FILE="${STATE_DIR}/launchd.log"
LAST_SESSION_FILE="${STATE_DIR}/last-session-id"
LABEL="com.haacked.ops-report-${KIND}"

usage() {
  cat <<EOF
Usage: $(basename "$0") <command> [daily|weekly]

Manage the ops-report LaunchAgents. The optional second argument selects the
agent (default: daily). The daily agent runs Tue–Fri; the weekly digest runs
Monday.

Commands:
  install    Create symlink and load the agent
  uninstall  Unload the agent and remove symlink
  start      Trigger the run now (via launchctl)
  stop       Unload the agent (disable scheduled runs)
  status     Show agent status and the last session ID
  logs       Tail the launchd log file
  run        Run the worker script directly (for testing)
  resume     Resume the most recent session in an interactive terminal

Examples:
  $(basename "$0") install          # Install the daily agent (Tue–Fri 9am)
  $(basename "$0") install weekly   # Install the weekly digest (Monday 9am)
  $(basename "$0") run weekly       # Generate this week's digest now, foreground
  $(basename "$0") resume           # Open the most recent daily session to iterate
  $(basename "$0") logs weekly      # Watch what the weekly agent did
EOF
  exit 0
}

cmd_install() {
  log_info "Installing ops-report-${KIND} LaunchAgent…"

  mkdir -p "$STATE_DIR"
  log_info "Created state directory: $STATE_DIR"

  if [[ ! -f "$PLIST_SOURCE" ]]; then
    log_error "Source plist not found: $PLIST_SOURCE"
    exit 1
  fi

  if [[ -L "$PLIST_DEST" ]]; then
    log_warn "Symlink already exists, recreating…"
    rm "$PLIST_DEST"
  elif [[ -f "$PLIST_DEST" ]]; then
    log_error "Regular file exists at $PLIST_DEST. Remove it first."
    exit 1
  fi

  ln -s "$PLIST_SOURCE" "$PLIST_DEST"
  log_info "Created symlink: $PLIST_DEST -> $PLIST_SOURCE"

  if launchctl list | grep -q "$LABEL"; then
    log_warn "Agent already loaded, reloading…"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
  fi

  launchctl load "$PLIST_DEST"
  log_success "LaunchAgent installed and loaded"
  log_info "Runs ${SCHEDULE_DESC}"
  log_info "Use '$(basename "$0") run ${KIND}' to test the worker now"
}

cmd_uninstall() {
  log_info "Uninstalling ops-report-${KIND} LaunchAgent…"

  if launchctl list | grep -q "$LABEL"; then
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
    log_info "Agent unloaded"
  fi

  if [[ -L "$PLIST_DEST" || -f "$PLIST_DEST" ]]; then
    rm "$PLIST_DEST"
    log_info "Removed: $PLIST_DEST"
  fi

  log_success "LaunchAgent uninstalled"
}

cmd_start() {
  log_info "Triggering ops-report-${KIND} run…"

  if ! launchctl list | grep -q "$LABEL"; then
    log_error "Agent not loaded. Run 'install' first."
    exit 1
  fi

  launchctl start "$LABEL"
  log_success "Run started"
  log_info "Use '$(basename "$0") logs' to watch progress"
}

cmd_stop() {
  log_info "Stopping LaunchAgent…"

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

  local agent_line
  agent_line=$(launchctl list | grep "$LABEL" || true)
  if [[ -n "$agent_line" ]]; then
    echo -e "Agent:    ${GREEN}loaded${NC}"
    local status
    status=$(awk '{print $1}' <<<"$agent_line")
    if [[ "$status" == "-" ]]; then
      echo "Last run: never (or currently running)"
    elif [[ "$status" == "0" ]]; then
      echo -e "Last run: ${GREEN}success (exit 0)${NC}"
    else
      echo -e "Last run: ${RED}failed (exit $status)${NC}"
    fi
  else
    echo -e "Agent:    ${RED}not loaded${NC}"
  fi

  if [[ -f "$LOG_FILE" ]]; then
    local log_size log_lines
    log_size=$(du -h "$LOG_FILE" | cut -f1)
    log_lines=$(wc -l < "$LOG_FILE" | tr -d ' ')
    echo "Log file: $LOG_FILE ($log_size, $log_lines lines)"
  else
    echo "Log file: not created yet"
  fi

  if [[ -f "$LAST_SESSION_FILE" ]]; then
    local last_session
    last_session=$(cat "$LAST_SESSION_FILE")
    echo "Last session: $last_session"
    echo "  Resume with: cd ${REPO_ROOT} && claude --resume $last_session"
  else
    echo "Last session: none recorded"
  fi
}

cmd_logs() {
  if [[ ! -f "$LOG_FILE" ]]; then
    log_warn "Log file does not exist yet: $LOG_FILE"
    log_info "Run 'start' or 'run' to generate output"
    exit 0
  fi

  log_info "Tailing log file (Ctrl+C to stop)…"
  tail -f "$LOG_FILE"
}

cmd_run() {
  if [[ ! -x "$WORKER" ]]; then
    log_error "Worker not found or not executable: $WORKER"
    exit 1
  fi
  log_info "Running ${KIND} worker (${WINDOW} window) in foreground…"
  exec "$WORKER" "$WINDOW"
}

cmd_resume() {
  if [[ ! -f "$LAST_SESSION_FILE" ]]; then
    log_error "No recorded session yet. Run '$(basename "$0") run' first."
    exit 1
  fi
  local last_session
  last_session=$(cat "$LAST_SESSION_FILE")
  log_info "Resuming session $last_session from $REPO_ROOT"
  cd "$REPO_ROOT"
  exec claude --resume "$last_session"
}

if [[ $# -eq 0 ]]; then
  usage
fi

case "${1:-}" in
  install) cmd_install ;;
  uninstall) cmd_uninstall ;;
  start) cmd_start ;;
  stop) cmd_stop ;;
  status) cmd_status ;;
  logs) cmd_logs ;;
  run) cmd_run ;;
  resume) cmd_resume ;;
  -h|--help|help) usage ;;
  *)
    log_error "Unknown command: $1"
    usage
    ;;
esac
