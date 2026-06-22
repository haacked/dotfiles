#!/bin/bash
# Find the most recent standup notes file.
#
# Usage: standup-find.sh
#
# Output format (tab-separated):
#   <status>\t<path>\t<date>\t<posted_at>
# Where status is:
#   found    - Previous standup exists at the returned path
#   new      - No previous standup found
# And posted_at is the file's modified time in UTC ISO 8601 (e.g.
# 2026-06-17T16:00:00Z), used as the merge cutoff so PRs merged after the
# last standup was posted are picked up next time. Empty when status is "new".

set -euo pipefail

STANDUP_DIR="$HOME/dev/haacked/notes/PostHog/standup"

# Ensure directory exists
mkdir -p "$STANDUP_DIR"

# Find the most recent standup file (YYYY-MM-DD.md format, sorted descending)
latest=$(find "$STANDUP_DIR" -maxdepth 1 -name "????-??-??.md" -type f 2>/dev/null | sort -r | head -1)

if [[ -n "$latest" ]]; then
    # Extract date from filename
    filename=$(basename "$latest" .md)
    # File modified time in UTC ISO 8601, used as the merge cutoff.
    if [[ "$OSTYPE" == "darwin"* ]]; then
        posted_at=$(date -u -r "$latest" +%Y-%m-%dT%H:%M:%SZ)
    else
        posted_at=$(date -u -d "@$(stat -c %Y "$latest")" +%Y-%m-%dT%H:%M:%SZ)
    fi
    echo -e "found\t${latest}\t${filename}\t${posted_at}"
else
    echo -e "new\t\t\t"
fi
