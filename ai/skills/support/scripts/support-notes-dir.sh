#!/bin/bash
# Get the full path for support notes given a ticket type and number, or a ticket URL.
# Usage: support-notes-dir.sh <ticket_type> <ticket_number>
#        support-notes-dir.sh <ticket_url>
# Example: support-notes-dir.sh zendesk 40875
#          support-notes-dir.sh https://us.posthog.com/project/2/support/tickets/3064
# Output: /Users/you/dev/ai/support/2025-12-22/zendesk-40875

set -euo pipefail

# Validate and normalize the arguments via the sibling script, which reports its own
# usage and exits non-zero when they're missing or malformed.
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
parsed=$("${script_dir}/support-parse-ticket.sh" "$@")
IFS=$'\t' read -r ticket_type ticket_number <<< "$parsed"

# Get the week directory from sibling script
week_dir=$("${script_dir}/support-week-dir.sh")

echo "${week_dir}/${ticket_type}-${ticket_number}"
