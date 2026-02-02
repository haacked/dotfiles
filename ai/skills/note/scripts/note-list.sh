#!/bin/bash
# List all notes for the current git repository.
#
# Usage: note-list.sh
#
# Output format (tab-separated, one per line):
#   <slug>\t<path>\t<title>
# Where title is extracted from the first H1 heading in the file.
#
# If no notes exist, outputs nothing and exits with code 0.

set -euo pipefail

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
    notes_dir="$HOME/dev/haacked/notes/PostHog/repositories/${repo}"
else
    notes_dir="$HOME/dev/ai/notes/${org}/${repo}"
fi

# Check if notes directory exists
if [[ ! -d "$notes_dir" ]]; then
    exit 0
fi

# List all markdown files and extract metadata
for note_path in "$notes_dir"/*.md; do
    # Skip if no files match (glob returns literal pattern)
    [[ -f "$note_path" ]] || continue

    # Extract slug from filename
    slug=$(basename "$note_path" .md)

    # Extract title from first H1 heading
    title=$(head -20 "$note_path" | grep -m1 '^# ' | sed 's/^# //' || echo "(no title)")

    echo -e "${slug}\t${note_path}\t${title}"
done
