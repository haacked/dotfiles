#!/bin/bash
# Detect current and previous sprint issues from the PostHog/posthog repository.
#
# Searches for issues with the `sprint` label and parses their titles
# ("Sprint - Feb 23 to March 8") to extract date ranges. Returns the
# current sprint (whose range includes today) and the immediately
# preceding one.
#
# Usage: detect-sprint.sh
#
# Output format (tab-separated, single line):
#   current_number\tcurrent_title\tsprint_start\tsprint_end\tprev_number\tprev_title\tprev_start\tprev_end

set -euo pipefail

# Pass JSON via stdin to avoid code injection through crafted issue titles.
gh issue list \
  --repo PostHog/posthog \
  --label sprint \
  --state all \
  --limit 10 \
  --json number,title \
  | python3 "$(dirname "$0")/parse-sprints.py"
