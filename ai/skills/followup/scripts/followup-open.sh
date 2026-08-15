#!/usr/bin/env bash
# Print open follow-up items, newest first, optionally filtered to one org/repo.
#
# Usage: followup-open.sh [org/repo]
#
# The single owner of open-item selection (`- [ ]` lines in the followups
# file) — other scripts and skills call this instead of re-deriving the grep.
# Prints nothing (exit 0) when the file is missing or no items match.

set -euo pipefail

FOLLOWUPS_FILE="${FOLLOWUPS_FILE:-$HOME/dev/haacked/notes/PostHog/Followups.md}"

[[ -f "$FOLLOWUPS_FILE" ]] || exit 0

if [[ $# -ge 1 && -n "$1" ]]; then
    # Anchor the context bracket to its fixed position after the date so a repo
    # name in an item's body can't cross-match another repo's filter, and one
    # repo name can't prefix-match another (posthog vs posthog-js).
    re_repo=${1//./\\.}
    grep -E "^- \[ \] [0-9]{4}-[0-9]{2}-[0-9]{2} · \[${re_repo}( ·|\])" "$FOLLOWUPS_FILE" || true
else
    grep '^- \[ \]' "$FOLLOWUPS_FILE" || true
fi
