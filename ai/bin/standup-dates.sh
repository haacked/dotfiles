#!/bin/bash
# Calculate standup-related dates.
# Standups happen on Monday, Wednesday, and Friday.
#
# Usage: standup-dates.sh
#
# Output format (tab-separated):
#   <today>\t<last_standup_date>\t<new_file_path>
#
# Example: 2026-01-30\t2026-01-29\t/path/to/standup/2026-01-30.md

set -euo pipefail

STANDUP_DIR="$HOME/dev/haacked/notes/PostHog/standup"

# Ensure directory exists
mkdir -p "$STANDUP_DIR"

today=$(date +%Y-%m-%d)
day_of_week=$(date +%u)  # 1=Monday, 7=Sunday

# Calculate days since last standup
# Standups are on Mon(1), Wed(3), Fri(5)
case $day_of_week in
    1)  # Monday - last standup was Friday (3 days ago)
        days_back=3
        ;;
    2)  # Tuesday - last standup was Monday (1 day ago)
        days_back=1
        ;;
    3)  # Wednesday - last standup was Monday (2 days ago)
        days_back=2
        ;;
    4)  # Thursday - last standup was Wednesday (1 day ago)
        days_back=1
        ;;
    5)  # Friday - last standup was Wednesday (2 days ago)
        days_back=2
        ;;
    6)  # Saturday - last standup was Friday (1 day ago)
        days_back=1
        ;;
    7)  # Sunday - last standup was Friday (2 days ago)
        days_back=2
        ;;
esac

if [[ "$OSTYPE" == "darwin"* ]]; then
    last_standup=$(date -v-${days_back}d +%Y-%m-%d)
else
    last_standup=$(date -d "${days_back} days ago" +%Y-%m-%d)
fi

new_file="${STANDUP_DIR}/${today}.md"

echo -e "${today}\t${last_standup}\t${new_file}"
