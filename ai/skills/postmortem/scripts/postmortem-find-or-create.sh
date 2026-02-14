#!/usr/bin/env bash
#
# postmortem-find-or-create.sh <id-or-slug>
#
# Find existing postmortem or return path for new one.
# Output format: status\tpath\tincident_id\ttitle\tdoc_status
# Status: "found" or "new"

set -euo pipefail

POSTMORTEM_DIR="${HOME}/dev/ai/postmortems/PostHog"

if [[ $# -lt 1 ]]; then
    echo "Usage: postmortem-find-or-create.sh <incident-id-or-slug>" >&2
    exit 1
fi

input="$1"

# Normalize: convert INC-123 format to lowercase slug
if [[ "$input" =~ ^[Ii][Nn][Cc]-([0-9]+)$ ]]; then
    # incident.io format - keep as-is but lowercase
    slug=$(echo "$input" | tr '[:upper:]' '[:lower:]')
else
    # Already a slug - just lowercase and sanitize
    slug=$(echo "$input" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9-]/-/g' | sed 's/--*/-/g' | sed 's/^-//' | sed 's/-$//')
fi

postmortem_path="${POSTMORTEM_DIR}/${slug}.md"

# Check if postmortem exists
if [[ -f "$postmortem_path" ]]; then
    # Extract metadata from existing file
    incident_id=""
    title=""
    doc_status=""

    if head -50 "$postmortem_path" | grep -q "^incident_id:"; then
        incident_id=$(head -50 "$postmortem_path" | grep "^incident_id:" | head -1 | sed 's/^incident_id:[[:space:]]*//')
    fi

    if head -50 "$postmortem_path" | grep -q "^title:"; then
        title=$(head -50 "$postmortem_path" | grep "^title:" | head -1 | sed 's/^title:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')
    fi

    if head -50 "$postmortem_path" | grep -q "^status:"; then
        doc_status=$(head -50 "$postmortem_path" | grep "^status:" | head -1 | sed 's/^status:[[:space:]]*//')
    fi

    printf "found\t%s\t%s\t%s\t%s\n" "$postmortem_path" "$incident_id" "$title" "$doc_status"
else
    # Return path for new postmortem
    printf "new\t%s\t%s\t\t\n" "$postmortem_path" "$slug"
fi
