#!/bin/bash
# Normalize support ticket arguments into a ticket type and number.
# Accepts a type plus a number, or a pasted ticket URL. Sibling scripts call this
# to validate their own arguments, so the messages below name no script.
#
# Usage: support-parse-ticket.sh <ticket_type> <ticket_number>
#        support-parse-ticket.sh <ticket_url>
# Example: support-parse-ticket.sh posthog 3064
#          support-parse-ticket.sh https://us.posthog.com/project/2/support/tickets/3064
#
# Output format (tab-separated):
#   <ticket_type>\t<ticket_number>

set -euo pipefail

usage() {
    echo "Expected arguments: <ticket_type> <ticket_number>, or a single <ticket_url>" >&2
    echo "  ticket_type: posthog, zendesk, or github" >&2
    echo "  ticket_number: numeric ticket ID" >&2
    echo "  ticket_url: an in-app, Zendesk, or GitHub issue ticket URL" >&2
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

if [[ $# -eq 1 ]]; then
    # Match on the URL's distinguishing path so trailing segments, query strings,
    # and fragments in a pasted URL don't matter.
    url="$1"
    if [[ "$url" =~ posthog\.com/project/[0-9]+/support/tickets/([0-9]+) ]]; then
        ticket_type="posthog"
        ticket_number="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ zendesk\.com/agent/tickets/([0-9]+) ]]; then
        ticket_type="zendesk"
        ticket_number="${BASH_REMATCH[1]}"
    elif [[ "$url" =~ github\.com/[^/]+/[^/]+/issues/([0-9]+) ]]; then
        ticket_type="github"
        ticket_number="${BASH_REMATCH[1]}"
    else
        echo "Error: unrecognized ticket URL: ${url}" >&2
        usage
        exit 1
    fi
else
    ticket_type="$1"
    ticket_number="$2"
fi

if [[ "$ticket_type" != "posthog" && "$ticket_type" != "zendesk" && "$ticket_type" != "github" ]]; then
    echo "Error: ticket_type must be 'posthog', 'zendesk', or 'github'" >&2
    exit 1
fi

if ! [[ "$ticket_number" =~ ^[0-9]+$ ]]; then
    echo "Error: ticket_number must be numeric" >&2
    exit 1
fi

printf '%s\t%s\n' "$ticket_type" "$ticket_number"
