#!/usr/bin/env python3
"""Print the Unix-epoch window that covers both possible support-hero bot posts.

The rotation bot posts a Friday preview 3 days before a sprint's first Monday
and a Monday announcement on that Monday itself. This prints one window
spanning both, midnight to midnight local time, so a single slack_read_channel
call catches whichever post exists.

Usage: support-hero-window.py <sprint_start>
  <sprint_start>: YYYY-MM-DD, the sprint's first Monday (from detect-sprint.sh)

Output (tab-separated, single line): oldest\tlatest
  oldest: midnight 3 days before sprint_start (Unix epoch seconds)
  latest: midnight the day after sprint_start (Unix epoch seconds)
"""

import sys
from datetime import datetime, timedelta


def window_bounds(sprint_start):
    monday = datetime.strptime(sprint_start, "%Y-%m-%d")
    oldest = monday - timedelta(days=3)
    latest = monday + timedelta(days=1)
    return int(oldest.timestamp()), int(latest.timestamp())


def main():
    if len(sys.argv) != 2:
        print("Usage: support-hero-window.py <sprint_start>", file=sys.stderr)
        sys.exit(1)

    oldest, latest = window_bounds(sys.argv[1])
    print(f"{oldest}\t{latest}")


if __name__ == "__main__":
    main()
