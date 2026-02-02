#!/bin/bash
# Get the full path for support notes given a ticket type and number.
# Usage: support-notes-dir.sh <ticket_type> <ticket_number>
# Example: support-notes-dir.sh zendesk 40875
# Output: /Users/you/dev/ai/support/2025-12-22/zendesk-40875

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: support-notes-dir.sh <ticket_type> <ticket_number>" >&2
    echo "  ticket_type: zendesk or github" >&2
    echo "  ticket_number: numeric ticket ID" >&2
    exit 1
fi

ticket_type="$1"
ticket_number="$2"

# Validate ticket type
if [[ "$ticket_type" != "zendesk" && "$ticket_type" != "github" ]]; then
    echo "Error: ticket_type must be 'zendesk' or 'github'" >&2
    exit 1
fi

# Validate ticket number is numeric
if ! [[ "$ticket_number" =~ ^[0-9]+$ ]]; then
    echo "Error: ticket_number must be numeric" >&2
    exit 1
fi

# Get the week directory from sibling script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
week_dir=$("${script_dir}/support-week-dir.sh")

echo "${week_dir}/${ticket_type}-${ticket_number}"
