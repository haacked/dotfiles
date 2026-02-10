#!/usr/bin/env bash
#
# postmortem-list.sh
#
# List all postmortems with metadata.
# Output format: path\tincident_id\ttitle\tdoc_status\tdate

set -euo pipefail

POSTMORTEM_DIR="${HOME}/dev/ai/postmortems/PostHog"

# Ensure directory exists
mkdir -p "$POSTMORTEM_DIR"

# Check if any postmortems exist
shopt -s nullglob
files=("$POSTMORTEM_DIR"/*.md)
shopt -u nullglob

if [[ ${#files[@]} -eq 0 ]]; then
    echo "No postmortems found in ${POSTMORTEM_DIR}" >&2
    exit 0
fi

# Output header
printf "path\tincident_id\ttitle\tstatus\tdate\n"

for file in "${files[@]}"; do
    incident_id=""
    title=""
    doc_status=""
    date=""

    # Extract metadata from frontmatter (first 50 lines should be enough)
    frontmatter=$(head -50 "$file")

    if echo "$frontmatter" | grep -q "^incident_id:"; then
        incident_id=$(echo "$frontmatter" | grep "^incident_id:" | head -1 | sed 's/^incident_id:[[:space:]]*//')
    fi

    if echo "$frontmatter" | grep -q "^title:"; then
        title=$(echo "$frontmatter" | grep "^title:" | head -1 | sed 's/^title:[[:space:]]*//' | sed 's/^"//' | sed 's/"$//')
    fi

    if echo "$frontmatter" | grep -q "^status:"; then
        doc_status=$(echo "$frontmatter" | grep "^status:" | head -1 | sed 's/^status:[[:space:]]*//')
    fi

    if echo "$frontmatter" | grep -q "^date:"; then
        date=$(echo "$frontmatter" | grep "^date:" | head -1 | sed 's/^date:[[:space:]]*//')
    fi

    printf "%s\t%s\t%s\t%s\t%s\n" "$file" "$incident_id" "$title" "$doc_status" "$date"
done
