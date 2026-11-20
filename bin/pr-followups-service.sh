#!/usr/bin/env bash
# pr-followups-service.sh - Manage the PR follow-ups LaunchAgent.
#
# Usage:
#   pr-followups-service.sh [install|uninstall|start|stop|status|logs|run|resume]
#
# Commands are provided by lib/launchd-service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="pr-followups"
WORKER="${SCRIPT_DIR}/pr-followups-run"
SCHEDULE_DESC="Monday to Friday at 07:45 local time"

launchd_service_main "$@"
