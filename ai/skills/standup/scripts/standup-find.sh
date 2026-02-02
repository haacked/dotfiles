#!/bin/bash
# Find the most recent standup notes file.
#
# Usage: standup-find.sh
#
# Output format (tab-separated):
#   <status>\t<path>\t<date>
# Where status is:
#   found    - Previous standup exists at the returned path
#   new      - No previous standup found

set -euo pipefail

STANDUP_DIR="$HOME/dev/haacked/notes/PostHog/standup"

# Ensure directory exists
mkdir -p "$STANDUP_DIR"

# Find the most recent standup file (YYYY-MM-DD.md format, sorted descending)
latest=$(find "$STANDUP_DIR" -maxdepth 1 -name "????-??-??.md" -type f 2>/dev/null | sort -r | head -1)

if [[ -n "$latest" ]]; then
    # Extract date from filename
    filename=$(basename "$latest" .md)
    echo -e "found\t${latest}\t${filename}"
else
    echo -e "new\t\t"
fi
