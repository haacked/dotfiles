#!/bin/bash
# Resolve a support log target week (Monday + Friday + directory).
# Used by /support log to figure out which week to summarize.
#
# Usage:
#   support-log-week.sh                  # default: most recent completed week (last Monday)
#   support-log-week.sh --last           # explicit: most recent completed week
#   support-log-week.sh --current        # current week (Monday of this week)
#   support-log-week.sh YYYY-MM-DD       # explicit Monday date
#
# Output (tab-separated):
#   <monday-date>\t<friday-date>\t<dir-path>
#
# Examples:
#   $ support-log-week.sh --last
#   2026-04-20	2026-04-24	/Users/you/dev/ai/support/2026-04-20

set -euo pipefail

mode="last"
explicit_monday=""

if [[ $# -ge 1 ]]; then
    case "$1" in
        --current) mode="current" ;;
        --last)    mode="last" ;;
        [0-9]*)
            mode="explicit"
            explicit_monday="$1"
            ;;
        -h|--help)
            grep '^#' "$0" | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *)
            echo "Usage: $0 [--current|--last|YYYY-MM-DD]" >&2
            exit 1
            ;;
    esac
fi

if [[ "$mode" == "explicit" ]]; then
    monday_date="$explicit_monday"
else
    day_of_week=$(date +%u)
    days_to_monday=$((day_of_week - 1))
    if [[ "$mode" == "last" ]]; then
        days_to_monday=$((days_to_monday + 7))
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        monday_date=$(date -v-${days_to_monday}d +%Y-%m-%d)
    else
        monday_date=$(date -d "${days_to_monday} days ago" +%Y-%m-%d)
    fi
fi

if [[ "$OSTYPE" == "darwin"* ]]; then
    friday_date=$(date -j -v+4d -f %Y-%m-%d "$monday_date" +%Y-%m-%d)
else
    friday_date=$(date -d "$monday_date + 4 days" +%Y-%m-%d)
fi

dir="$HOME/dev/ai/support/${monday_date}"

printf '%s\t%s\t%s\n' "$monday_date" "$friday_date" "$dir"
