#!/usr/bin/env bash
# Resolve where notes and plans live for a repo — the single owner of the
# org/repo → vault-path mapping. PostHog repos are single-org and flat;
# everything else nests under Dev/repositories/{org}/{repo}.
#
# Usage: notes-path.sh <org/repo> [notes|plans]
# Prints the directory path: the repo's topic-note dir, or its plans dir.

set -euo pipefail

if [[ $# -lt 1 || "$1" != */* ]]; then
    echo "Usage: notes-path.sh <org/repo> [notes|plans]" >&2
    exit 1
fi

org="${1%%/*}"
repo="${1#*/}"
kind="${2:-notes}"

org_lower=$(echo "$org" | tr '[:upper:]' '[:lower:]')
if [[ "$org_lower" == "posthog" ]]; then
    base="$HOME/dev/haacked/notes/PostHog/repositories/${repo}"
else
    base="$HOME/dev/haacked/notes/Dev/repositories/${org}/${repo}"
fi

case "$kind" in
    notes) printf '%s\n' "$base" ;;
    plans) printf '%s\n' "$base/plans" ;;
    *) echo "Error: kind must be notes or plans" >&2; exit 1 ;;
esac
