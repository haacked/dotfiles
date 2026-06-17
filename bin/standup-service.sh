#!/usr/bin/env bash
# standup-service.sh - Manage the standup notes LaunchAgent.
#
# Usage:
#   standup-service.sh [install|uninstall|start|stop|status|logs|run|resume]
#
# Commands are provided by lib/launchd-service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="standup"
WORKER="${SCRIPT_DIR}/standup-run"
SCHEDULE_DESC="Monday, Wednesday, Friday at 08:15 local time"

launchd_service_main "$@"
