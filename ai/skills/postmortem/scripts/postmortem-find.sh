#!/usr/bin/env bash
#
# postmortem-find.sh [slug]
#
# Find specific postmortem by slug.
# If no slug provided, delegates to postmortem-list.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

if [[ $# -lt 1 ]]; then
    exec "${SCRIPT_DIR}/postmortem-list.sh"
fi

exec "${SCRIPT_DIR}/postmortem-find-or-create.sh" "$1"
