#!/usr/bin/env python3
"""Decide whether Claude Code's JSON output reports a usage limit.

Usage: claude_usage_limit.py <output-file>
Prints the limit message and exits 0 when a line of the file reports a usage limit.
Exits 1 otherwise.
"""

import json
import re
import sys

# Claude Code 2.1.318 treats an error message that starts with one of these as a usage limit.
USAGE_LIMIT_PREFIXES = (
    "You've hit your",
    "You've reached your",
    "You're out of usage credits",
    "You're out of extra usage",
    "Your org is out of usage",
    "Your seat type doesn't include",
    "Your usage allocation has been disabled",
    "Your group's usage limit",
    "Fable 5 requires usage credits",
)
# Claude Code 2.1.318 also treats a message that matches this expression as a usage limit.
USAGE_LIMIT_PATTERN = re.compile(
    r"^(?:Fable|Haiku|Mythos|Opus|Sonnet)(?: [^·\n]{1,40})? requires usage credits\."
)
API_LIMIT_ERRORS = ("rate_limit_error", "overloaded_error")


def usage_limit_message(event):
    """Returns the usage-limit message that one output event carries, or None.

    Review prose can mention limits. Only an error result or an API error event counts.
    """
    if not isinstance(event, dict):
        return None
    if event.get("type") == "result" and event.get("is_error") is True:
        errors = event.get("errors")
        for message in [event.get("result"), *(errors if isinstance(errors, list) else [])]:
            if isinstance(message, str) and (
                message.startswith(USAGE_LIMIT_PREFIXES) or USAGE_LIMIT_PATTERN.match(message)
            ):
                return message
    if event.get("type") == "error":
        error = event.get("error")
        if isinstance(error, dict) and error.get("type") in API_LIMIT_ERRORS:
            return error["type"]
    return None


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    with open(argv[1], encoding="utf-8", errors="replace") as output:
        for line in output:
            try:
                event = json.loads(line)
            except ValueError:
                continue
            message = usage_limit_message(event)
            if message is not None:
                # The exit status carries the verdict. A character that stdout can't encode must not change it.
                encoding = sys.stdout.encoding or "utf-8"
                print(message.encode(encoding, "backslashreplace").decode(encoding))
                return 0
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
