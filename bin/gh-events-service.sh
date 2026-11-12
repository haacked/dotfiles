#!/usr/bin/env bash
# gh-events-service.sh - Manage the gh-events LaunchAgent
#
# Usage:
#   gh-events-service.sh [install|uninstall|start|stop|status|logs|run]
#
# Commands are provided by lib/launchd-service.sh. The agent runs
# `gh-events run` continuously, and launchd restarts it when it exits.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="gh-events"
WORKER="${SCRIPT_DIR}/gh-events"
WORKER_ARGS=(run)
SCHEDULE_DESC="continuously, restarted by launchd when it exits"
USAGE_DESC="Manage the ${SERVICE_NAME} LaunchAgent, which polls GitHub notifications and
watched PRs and appends PR events to ~/.local/state/gh-events/events.jsonl."
USAGE_EXTRA="Examples:
  $(basename "$0") install   # Install and start the daemon
  $(basename "$0") status    # Show the heartbeat, watches, and today's requests
  $(basename "$0") logs      # Watch what the daemon did
  gh-events stats            # Print request, event, and wait numbers"

service_status_extra() {
  echo ""
  "$WORKER" status
}

launchd_service_main "$@"
