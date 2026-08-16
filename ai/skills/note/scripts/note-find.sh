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

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../../helpers/repo-context.sh"

if ! derive_org_repo; then
    echo "Error: could not determine GitHub org/repo (not a git repo, no origin remote, or origin is not GitHub)" >&2
    exit 1
fi
org="$REPO_ORG"
repo="$REPO_REPO"

# Use different notes location for PostHog repos
org_lower=$(echo "$org" | tr '[:upper:]' '[:lower:]')
if [[ "$org_lower" == "posthog" ]]; then
    notes_base="$HOME/dev/haacked/notes/PostHog/repositories"
    note_path="${notes_base}/${repo}/${slug}.md"
else
    notes_base="$HOME/dev/haacked/notes/Dev/repositories"
    note_path="${notes_base}/${org}/${repo}/${slug}.md"
fi

if [[ -f "$note_path" ]]; then
    echo -e "found\t${note_path}"
else
    echo -e "new\t${note_path}"
fi
