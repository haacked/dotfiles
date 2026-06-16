#!/usr/bin/env bash
# sprint-status-service.sh - Manage the weekly sprint status LaunchAgent.
#
# Usage:
#   sprint-status-service.sh [install|uninstall|start|stop|status|logs|run|resume]
#
# Commands are provided by lib/launchd-service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="sprint-status"
WORKER="${SCRIPT_DIR}/sprint-status-run"
SCHEDULE_DESC="Wednesday at 07:00 local time"

launchd_service_main "$@"
