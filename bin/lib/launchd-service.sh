#!/usr/bin/env bash
# launchd-service.sh - Shared command implementation for LaunchAgent service
# scripts (install/uninstall/start/stop/status/logs/run/resume).
#
# A service script sources this file (after logging.sh), sets the variables
# below, optionally defines the hooks, and finally calls
# `launchd_service_main "$@"`.
#
# Required:
#   SERVICE_NAME   short name, e.g. triage-daily. Derives the launchd label
#                  (com.haacked.<name>), the plist basename, and the state
#                  directory (~/.local/state/<name>, which also holds the
#                  launchd log and the last recorded session id).
#   WORKER         absolute path to the worker executable used by `run`
#
# Optional:
#   WORKER_ARGS    array of arguments `run` passes to the worker
#   SCHEDULE_DESC  human-readable schedule shown by `install`
#   REPO_ROOT      working dir for `resume` (default: this repo's root)
#   USAGE_ARGS     extra argument hint appended to the usage line
#   USAGE_DESC     description paragraph for usage (default names the agent)
#   USAGE_EXTRA    extra usage text (e.g. an Examples block)
#
# Hooks (define after sourcing to extend behavior):
#   service_status_extra   called at the end of `status`

_svc_init() {
  SERVICE_LABEL="com.haacked.${SERVICE_NAME}"
  PLIST_NAME="${SERVICE_LABEL}.plist"
  PLIST_SOURCE="${HOME}/.dotfiles/macos/LaunchAgents/${PLIST_NAME}"
  PLIST_DEST="${HOME}/Library/LaunchAgents/${PLIST_NAME}"
  STATE_DIR="${HOME}/.local/state/${SERVICE_NAME}"
  LOG_FILE="${STATE_DIR}/launchd.log"
  LAST_SESSION_FILE="${STATE_DIR}/last-session-id"
  if [[ -z "${REPO_ROOT:-}" ]]; then
    REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>${USAGE_ARGS:+ ${USAGE_ARGS}}

${USAGE_DESC:-Manage the ${SERVICE_LABEL} LaunchAgent.}

Commands:
  install    Create symlink and load the agent
  uninstall  Unload the agent and remove symlink
  start      Trigger the run now (via launchctl)
  stop       Unload the agent (disable scheduled runs)
  status     Show agent status
  logs       Tail the launchd log file
  run        Run the worker script directly (for testing)
  resume     Resume the most recent session in an interactive terminal
${USAGE_EXTRA:+
${USAGE_EXTRA}}
EOF
  exit "${1:-0}"
}

cmd_install() {
  log_info "Installing ${SERVICE_LABEL} LaunchAgent…"

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

  if launchctl list | grep -q "$SERVICE_LABEL"; then
    log_warn "Agent already loaded, reloading…"
    launchctl unload "$PLIST_DEST" 2>/dev/null || true
  fi

  launchctl load "$PLIST_DEST"
  log_success "LaunchAgent installed and loaded"
  [[ -n "${SCHEDULE_DESC:-}" ]] && log_info "Runs ${SCHEDULE_DESC}"
  log_info "Use '$(basename "$0") run' to test the worker now"
}

cmd_uninstall() {
  log_info "Uninstalling ${SERVICE_LABEL} LaunchAgent…"

  if launchctl list | grep -q "$SERVICE_LABEL"; then
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
  log_info "Triggering ${SERVICE_LABEL} run…"

  if ! launchctl list | grep -q "$SERVICE_LABEL"; then
    log_error "Agent not loaded. Run 'install' first."
    exit 1
  fi

  launchctl start "$SERVICE_LABEL"
  log_success "Run started"
  log_info "Use '$(basename "$0") logs' to watch progress"
}

cmd_stop() {
  log_info "Stopping LaunchAgent…"

  if launchctl list | grep -q "$SERVICE_LABEL"; then
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
  agent_line=$(launchctl list | grep "$SERVICE_LABEL" || true)
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

  if declare -F service_status_extra >/dev/null; then
    service_status_extra
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
  log_info "Running worker in foreground…"
  exec "$WORKER" ${WORKER_ARGS[@]+"${WORKER_ARGS[@]}"} "$@"
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

launchd_service_main() {
  _svc_init

  if [[ $# -eq 0 ]]; then
    usage
  fi

  local command="$1"
  shift
  case "$command" in
    install) cmd_install ;;
    uninstall) cmd_uninstall ;;
    start) cmd_start ;;
    stop) cmd_stop ;;
    status) cmd_status ;;
    logs) cmd_logs ;;
    run) cmd_run "$@" ;;
    resume) cmd_resume ;;
    -h|--help|help) usage ;;
    *)
      log_error "Unknown command: $command"
      usage 64
      ;;
  esac
}
