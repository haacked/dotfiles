"""Parse sprint issues and select the current and previous sprints.

Reads a JSON array of sprint issues (with 'number' and 'title' fields) from
stdin. Parses date ranges from titles like "Sprint - Feb 23 to March 8" and
outputs the current and previous sprint as tab-separated fields.

Usage: echo "$json" | python3 parse-sprints.py

Output format (tab-separated, single line):
  current_number\tcurrent_title\tsprint_start\tsprint_end\tprev_number\tprev_title\tprev_start\tprev_end
"""

import json
import re
import sys
from datetime import date, datetime


def parse_date(s, reference_year):
    """Parse a date string, optionally appending a reference year.

    Handles both abbreviated and full month names. Tries parsing the string
    as-is first (for titles that include an explicit year like 'Feb 23 2026'),
    then falls back to appending the reference year ('Feb 23' + ' 2026').
    """
    # If the string already includes a year (e.g., 'Feb 23 2026'), parse it directly.
    for fmt in ("%B %d %Y", "%b %d %Y"):
        try:
            return datetime.strptime(s, fmt).date()
        except ValueError:
            continue
    # Otherwise, append the reference year (e.g., 'Feb 23' becomes 'Feb 23 2026').
    for fmt in ("%B %d %Y", "%b %d %Y"):
        try:
            return datetime.strptime(f"{s} {reference_year}", fmt).date()
        except ValueError:
            continue
    return None


def parse_sprint_dates(title, today):
    """Parse 'Sprint - Feb 23 to March 8' into (start_date, end_date).

    The title rarely includes the year, so we try candidate years and pick
    the range closest to today. This handles Dec-to-Jan sprints correctly: if
    today is Jan 2026, "Dec 30 to Jan 13" should resolve to 2025-12-30 through
    2026-01-13 rather than 2026-12-30 through 2027-01-13.
    """
    m = re.match(r"Sprint\s*-\s*(.+?)\s+to\s+(.+)", title, re.IGNORECASE)
    if not m:
        return None, None

    start_str = m.group(1).strip()
    end_str = m.group(2).strip()

    best = None
    for year in [today.year, today.year - 1, today.year + 1]:
        start = parse_date(start_str, year)
        end = parse_date(end_str, year)
        if start and end:
            if end < start:
                end = end.replace(year=end.year + 1)
            distance = abs((start - today).days)
            if best is None or distance < best[0]:
                best = (distance, start, end)

    if best:
        return best[1], best[2]
    return None, None


def select_sprints(sprints, today):
    """Select the current and previous sprints from a list of parsed sprints."""
    parsed = []
    for s in sprints:
        start, end = parse_sprint_dates(s["title"], today)
        if start and end:
            parsed.append({
                "number": s["number"],
                "title": s["title"],
                "start": start,
                "end": end,
            })

    # Sort by start date descending (most recent first).
    parsed.sort(key=lambda x: x["start"], reverse=True)

    # Find the current sprint: today falls within [start, end].
    current = None
    for s in parsed:
        if s["start"] <= today <= s["end"]:
            current = s
            break

    # If no exact match, pick the sprint with the nearest start date on or before today.
    if not current:
        for s in parsed:
            if s["start"] <= today:
                current = s
                break

    if not current and parsed:
        current = parsed[0]

    # Previous sprint is the one immediately before current in chronological order.
    prev = None
    if current:
        for s in parsed:
            if s["start"] < current["start"]:
                prev = s
                break

    return current, prev


def fmt(s):
    """Format a sprint as tab-separated fields, or NOT_FOUND sentinels."""
    if s is None:
        return "NOT_FOUND\tNOT_FOUND\tNOT_FOUND\tNOT_FOUND"
    return f"{s['number']}\t{s['title']}\t{s['start'].isoformat()}\t{s['end'].isoformat()}"


def main():
    sprints = json.load(sys.stdin)
    today = date.today()
    current, prev = select_sprints(sprints, today)
    print(f"{fmt(current)}\t{fmt(prev)}")


if __name__ == "__main__":
    main()
