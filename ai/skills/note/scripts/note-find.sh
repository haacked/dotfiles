#!/bin/bash
# Find an existing note by slug for the current git repository.
#
# Usage: note-find.sh <slug>
# Example: note-find.sh cohort-uploads
#
# Output format (tab-separated):
#   <status>\t<path>
# Where status is:
#   found    - Note exists at the returned path
#   new      - Note doesn't exist; path is where it would be created

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: note-find.sh <slug>" >&2
    echo "  slug: kebab-case name for the note (e.g., cohort-uploads, oauth-flow)" >&2
    exit 1
fi

slug="$1"

# Validate slug is kebab-case (lowercase letters, numbers, hyphens)
if ! [[ "$slug" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]; then
    echo "Error: slug must be kebab-case (e.g., cohort-uploads, oauth-flow)" >&2
    exit 1
fi

# Get org/repo from git remote
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    echo "Error: not in a git repository" >&2
    exit 1
fi

remote_url=$(git remote get-url origin 2>/dev/null || echo "")
if [[ -z "$remote_url" ]]; then
    echo "Error: no origin remote found" >&2
    exit 1
fi

# Parse org/repo from various git URL formats:
# - git@github.com:org/repo.git
# - https://github.com/org/repo.git
# - https://github.com/org/repo
if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
    org="${BASH_REMATCH[1]}"
    repo="${BASH_REMATCH[2]}"
else
    echo "Error: could not parse org/repo from remote URL: $remote_url" >&2
    exit 1
fi

# notes-path.sh owns the org/repo → vault-path mapping.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
note_path="$("$SCRIPT_DIR/notes-path.sh" "${org}/${repo}")/${slug}.md"

if [[ -f "$note_path" ]]; then
    echo -e "found\t${note_path}"
else
    echo -e "new\t${note_path}"
fi
