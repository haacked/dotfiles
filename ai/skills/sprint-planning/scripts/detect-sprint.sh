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

today=$(date +%Y-%m-%d)

sprints_json=$(gh issue list \
  --repo PostHog/posthog \
  --label sprint \
  --state all \
  --limit 10 \
  --json number,title)

python3 -c "
import json, sys, re
from datetime import datetime, date

sprints = json.loads('''$sprints_json''')
today = date.fromisoformat('$today')

def parse_sprint_dates(title):
    \"\"\"Parse 'Sprint - Feb 23 to March 8' into (start_date, end_date).\"\"\"
    m = re.match(r'Sprint\s*-\s*(.+?)\s+to\s+(.+)', title, re.IGNORECASE)
    if not m:
        return None, None

    start_str = m.group(1).strip()
    end_str = m.group(2).strip()

    # Try parsing with explicit year first, then infer year from context.
    # We always append the reference year before parsing to avoid the Python 3.15
    # deprecation warning about parsing dates without a year.
    def parse_date(s, reference_year):
        for fmt in ('%B %d %Y', '%b %d %Y'):
            try:
                d = datetime.strptime(s, fmt).date()
                return d
            except ValueError:
                continue
        for fmt in ('%B %d %Y', '%b %d %Y'):
            try:
                d = datetime.strptime(f'{s} {reference_year}', fmt).date()
                return d
            except ValueError:
                continue
        return None

    # The title rarely includes the year, so we guess based on proximity to today.
    for year in [today.year, today.year - 1, today.year + 1]:
        start = parse_date(start_str, year)
        end = parse_date(end_str, year)
        if start and end:
            # If end month < start month, the sprint crosses a year boundary.
            if end < start:
                end = end.replace(year=end.year + 1)
            return start, end

    return None, None

parsed = []
for s in sprints:
    start, end = parse_sprint_dates(s['title'])
    if start and end:
        parsed.append({
            'number': s['number'],
            'title': s['title'],
            'start': start,
            'end': end,
        })

# Sort by start date descending (most recent first).
parsed.sort(key=lambda x: x['start'], reverse=True)

# Find the current sprint: today falls within [start, end].
current = None
for s in parsed:
    if s['start'] <= today <= s['end']:
        current = s
        break

# If no exact match, pick the sprint with the nearest start date on or before today.
if not current:
    for s in parsed:
        if s['start'] <= today:
            current = s
            break

if not current and parsed:
    current = parsed[0]

# Previous sprint is the one immediately before current in chronological order.
prev = None
if current:
    for s in parsed:
        if s['start'] < current['start']:
            prev = s
            break

def fmt(s):
    if s is None:
        return 'NOT_FOUND\tNOT_FOUND\tNOT_FOUND\tNOT_FOUND'
    return f\"{s['number']}\t{s['title']}\t{s['start'].isoformat()}\t{s['end'].isoformat()}\"

print(f'{fmt(current)}\t{fmt(prev)}')
"
