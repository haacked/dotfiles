#!/usr/bin/env bash
# Print open follow-up items, newest first, optionally filtered to one org/repo.
#
# Usage: followup-open.sh [org/repo]
#
# The single owner of the open-item grammar (`- [ ]` lines in the followups
# file) — other scripts and skills call this instead of re-deriving the grep.
# Prints nothing (exit 0) when the file is missing or no items match.

set -euo pipefail

FOLLOWUPS_FILE="${FOLLOWUPS_FILE:-$HOME/dev/haacked/notes/PostHog/Followups.md}"

[[ -f "$FOLLOWUPS_FILE" ]] || exit 0

if [[ $# -ge 1 && -n "$1" ]]; then
    grep '^- \[ \]' "$FOLLOWUPS_FILE" | grep -F "[${1}" || true
else
    grep '^- \[ \]' "$FOLLOWUPS_FILE" || true
fi
