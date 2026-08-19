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

valid_types="posthog, zendesk, github"

usage() {
    echo "Expected arguments: <ticket_type> <ticket_number>, or a single <ticket_url>" >&2
    echo "  ticket_type: ${valid_types}" >&2
    echo "  ticket_number: numeric ticket ID" >&2
    echo "  ticket_url: an in-app, Zendesk, or GitHub issue ticket URL" >&2
}

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

if [[ $# -eq 1 ]]; then
    # Anchored at the host so a look-alike domain can't pass, and matched only as far as
    # the ticket number so trailing segments, query strings, and fragments don't matter.
    # The scheme is optional because a copied URL doesn't always carry one.
    url="$1"
    if [[ "$url" =~ ^(https?://)?[a-z0-9-]+\.posthog\.com/project/[0-9]+/support/tickets/([0-9]+) ]]; then
        ticket_type="posthog"
        ticket_number="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^(https?://)?[a-z0-9-]+\.zendesk\.com/agent/tickets/([0-9]+) ]]; then
        ticket_type="zendesk"
        ticket_number="${BASH_REMATCH[2]}"
    elif [[ "$url" =~ ^(https?://)?(www\.)?github\.com/[^/]+/[^/]+/issues/([0-9]+) ]]; then
        ticket_type="github"
        ticket_number="${BASH_REMATCH[3]}"
    elif [[ "$url" != *"/"* ]]; then
        echo "Error: got one argument that is not a URL: ${url}" >&2
        usage
        exit 1
    else
        echo "Error: unrecognized ticket URL: ${url}" >&2
        usage
        exit 1
    fi
else
    ticket_type="$1"
    ticket_number="$2"
fi

case "$ticket_type" in
    posthog | zendesk | github) ;;
    *)
        echo "Error: ticket_type must be one of: ${valid_types}" >&2
        exit 1
        ;;
esac

if ! [[ "$ticket_number" =~ ^[0-9]+$ ]]; then
    echo "Error: ticket_number must be numeric" >&2
    exit 1
fi

printf '%s\t%s\n' "$ticket_type" "$ticket_number"
