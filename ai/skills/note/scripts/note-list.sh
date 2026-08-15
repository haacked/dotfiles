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

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../../helpers/repo-context.sh"

if ! derive_org_repo; then
    echo "Error: could not determine GitHub org/repo from the origin remote" >&2
    exit 1
fi
org="$REPO_ORG"
repo="$REPO_REPO"

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
