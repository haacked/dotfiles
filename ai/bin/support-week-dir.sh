#!/bin/bash
# Calculate the Monday of the current week and output the support directory path.
# Usage: support-week-dir.sh
# Output: ~/dev/ai/support/YYYY-MM-DD

set -euo pipefail

# Get current day of week (1=Monday, 7=Sunday in ISO format)
day_of_week=$(date +%u)

# Calculate days to subtract to get to Monday
# Monday (1) -> 0, Tuesday (2) -> 1, ..., Sunday (7) -> 6
days_to_monday=$((day_of_week - 1))

# Calculate Monday's date
if [[ "$OSTYPE" == "darwin"* ]]; then
    monday_date=$(date -v-${days_to_monday}d +%Y-%m-%d)
else
    monday_date=$(date -d "${days_to_monday} days ago" +%Y-%m-%d)
fi

echo "$HOME/dev/ai/support/${monday_date}"
