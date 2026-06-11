#!/usr/bin/env bash
# ops-report-service.sh - Manage the ops-report LaunchAgents (daily and weekly).
#
# Usage:
#   ops-report-service.sh <command> [daily|weekly]
#
# The optional second argument selects which agent to act on (default: daily).
# Commands are provided by lib/launchd-service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

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

SERVICE_NAME="ops-report-${KIND}"
WORKER="${SCRIPT_DIR}/ops-report-run"
WORKER_ARGS=("$WINDOW")

USAGE_ARGS="[daily|weekly]"
USAGE_DESC="Manage the ops-report LaunchAgents. The optional second argument selects the
agent (default: daily). The daily agent runs Tue–Fri; the weekly digest runs
Monday."
USAGE_EXTRA="Examples:
  $(basename "$0") install          # Install the daily agent (Tue–Fri 9am)
  $(basename "$0") install weekly   # Install the weekly digest (Monday 9am)
  $(basename "$0") run weekly       # Generate this week's digest now, foreground
  $(basename "$0") resume           # Open the most recent daily session to iterate
  $(basename "$0") logs weekly      # Watch what the weekly agent did"

launchd_service_main "${1:-}"
