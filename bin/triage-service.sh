#!/usr/bin/env bash
# triage-service.sh - Manage the daily Feature Flags triage LaunchAgent.
#
# Usage:
#   triage-service.sh [install|uninstall|start|stop|status|logs|run|resume]
#
# Commands are provided by lib/launchd-service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="triage-daily"
WORKER="${SCRIPT_DIR}/triage-run"
SCHEDULE_DESC="Mon–Fri at 08:30 local time"

launchd_service_main "$@"
