#!/bin/bash
# Find an existing support ticket directory, searching backwards through weeks.
# If not found, returns the path where it would be created (current week).
#
# Usage: support-find-ticket.sh <ticket_type> <ticket_number>
# Example: support-find-ticket.sh zendesk 40875
#
# Output format (tab-separated):
#   <status>\t<path>
# Where status is:
#   found    - Ticket exists at the returned path
#   new      - Ticket doesn't exist; path is where it would be created

set -euo pipefail

if [[ $# -lt 2 ]]; then
    echo "Usage: support-find-ticket.sh <ticket_type> <ticket_number>" >&2
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

support_base="$HOME/dev/ai/support"
ticket_dir_name="${ticket_type}-${ticket_number}"

# Search backwards from current week
# Check up to 52 weeks back (1 year)
max_weeks=52

for ((i=0; i<max_weeks; i++)); do
    if [[ "$OSTYPE" == "darwin"* ]]; then
        # macOS: get the Monday of week (i weeks ago)
        day_of_week=$(date +%u)
        days_to_monday=$((day_of_week - 1 + i * 7))
        monday_date=$(date -v-${days_to_monday}d +%Y-%m-%d)
    else
        # Linux
        day_of_week=$(date +%u)
        days_to_monday=$((day_of_week - 1 + i * 7))
        monday_date=$(date -d "${days_to_monday} days ago" +%Y-%m-%d)
    fi

    candidate_path="${support_base}/${monday_date}/${ticket_dir_name}"

    if [[ -d "$candidate_path" ]]; then
        echo -e "found\t${candidate_path}"
        exit 0
    fi
done

# Not found - return current week path for new ticket
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
new_path=$("${script_dir}/support-notes-dir.sh" "$ticket_type" "$ticket_number")
echo -e "new\t${new_path}"
