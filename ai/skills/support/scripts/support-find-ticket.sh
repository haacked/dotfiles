#!/bin/bash
# Find an existing support ticket directory, searching every week on record.
# If not found, returns the path where it would be created (current week).
#
# Usage: support-find-ticket.sh <ticket_type> <ticket_number>
#        support-find-ticket.sh <ticket_url>
# Example: support-find-ticket.sh zendesk 40875
#          support-find-ticket.sh https://us.posthog.com/project/2/support/tickets/3064
#
# Output format (tab-separated):
#   <status>\t<path>
# Where status is:
#   found    - Ticket exists at the returned path
#   new      - Ticket doesn't exist; path is where it would be created

set -euo pipefail

# Validate and normalize the arguments via the sibling script, which reports its own
# usage and exits non-zero when they're missing or malformed.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parsed=$("${script_dir}/support-parse-ticket.sh" "$@")
IFS=$'\t' read -r ticket_type ticket_number <<< "$parsed"

support_base="$HOME/dev/ai/support"
ticket_dir_name="${ticket_type}-${ticket_number}"

# Read the week directories rather than recomputing their names: notes sometimes get
# filed under a non-Monday date, which week math can't see. Their ISO names sort
# oldest to newest, so the last match is the most recent week.
found_dir=""
for candidate in "${support_base}"/[0-9]*/"${ticket_dir_name}"; do
    if [[ -d "$candidate" ]]; then
        found_dir="$candidate"
    fi
done

if [[ -n "$found_dir" ]]; then
    echo -e "found\t${found_dir}"
    exit 0
fi

# A Zendesk ticket migrated to the in-app inbox has its notes under posthog-{number},
# so an old Zendesk number only matches via the `Linked Zendesk` line in the notes.
# Anchored to that line so a passing mention of another ticket in an investigation
# log can't masquerade as the ticket's identity.
if [[ "$ticket_type" == "zendesk" ]]; then
    linked_notes=$(grep -rl --include=notes.md -E "^\*\*Linked Zendesk\*\*:.*zendesk/${ticket_number}([^0-9]|\$)" "$support_base" 2>/dev/null | sort -r | head -1 || true)
    if [[ -n "$linked_notes" ]]; then
        echo -e "found\t$(dirname "$linked_notes")"
        exit 0
    fi
fi

# Not found - return current week path for new ticket
new_path=$("${script_dir}/support-notes-dir.sh" "$ticket_type" "$ticket_number")
echo -e "new\t${new_path}"
