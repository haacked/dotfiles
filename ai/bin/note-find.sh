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

# Use different notes location for PostHog repos
org_lower=$(echo "$org" | tr '[:upper:]' '[:lower:]')
if [[ "$org_lower" == "posthog" ]]; then
    notes_base="$HOME/dev/haacked/notes/PostHog/repositories"
    note_path="${notes_base}/${repo}/${slug}.md"
else
    notes_base="$HOME/dev/ai/notes"
    note_path="${notes_base}/${org}/${repo}/${slug}.md"
fi

if [[ -f "$note_path" ]]; then
    echo -e "found\t${note_path}"
else
    echo -e "new\t${note_path}"
fi
