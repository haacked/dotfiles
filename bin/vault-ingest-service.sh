#!/usr/bin/env bash
# vault-ingest-service.sh - Manage the vault-ingest LaunchAgent.
#
# Usage:
#   vault-ingest-service.sh <command>
#
# Commands are provided by lib/launchd-service.sh.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/launchd-service.sh"

SERVICE_NAME="vault-ingest"
WORKER="${SCRIPT_DIR}/vault-ingest-run"
SCHEDULE_DESC="daily at 07:13 local time, draining 5 raw sources per run"

# `resume` must reopen the session in the same cwd the worker used.
REPO_ROOT="${HOME}/dev/haacked/notes"

USAGE_DESC="Manage the vault-ingest LaunchAgent, which drains the notes vault's
raw-source ingest backlog into wiki pages on a daily schedule."
USAGE_EXTRA="Examples:
  $(basename "$0") install   # Install the daily agent (07:13)
  $(basename "$0") run       # Ingest a tranche now, foreground
  $(basename "$0") resume    # Open the most recent ingest session to iterate
  $(basename "$0") logs      # Watch what the agent did"

launchd_service_main "$@"
