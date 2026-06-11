#!/usr/bin/env bash
# review-all-prs-service.sh - Manage the review-all-prs LaunchAgent
#
# Usage:
#   review-all-prs-service.sh [install|uninstall|start|stop|status|logs|run]
#
# Commands are provided by lib/launchd-service.sh.
#
# IMPORTANT: Run 'install' before the LaunchAgent runs to create the log
# directory. The LaunchAgent writes to ~/.local/state/review-all-prs/launchd.log
# which won't exist if install hasn't been run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="review-all-prs"
WORKER="${SCRIPT_DIR}/run-pr-reviews.sh"
WORKER_ARGS=(--auto)
SCHEDULE_DESC="hourly from 6 PM to 2 AM"

# Today's review session counts, appended to `status`.
service_status_extra() {
  local today session_file
  today=$(date +%Y-%m-%d)
  session_file="${STATE_DIR}/session-${today}.json"
  if [[ -f "$session_file" ]]; then
    local reviewed failed
    reviewed=$(jq '.reviewed | length' < "$session_file")
    failed=$(jq '.failed | length' < "$session_file")
    echo ""
    echo "Today's session:"
    echo "  Reviewed: $reviewed"
    echo "  Failed:   $failed"
  fi
}

launchd_service_main "$@"
