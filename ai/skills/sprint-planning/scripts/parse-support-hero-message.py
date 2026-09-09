#!/usr/bin/env python3
"""Extract the two support heroes from the rotation bot's Slack message text.

Reads message text from stdin (the concatenated text of any messages from the
bot in the read window; extra surrounding text is ignored) and prints JSON
`{"week1": {"id", "name"}, "week2": {"id", "name"}}` on a match, or NOT_FOUND
if neither shape matches.

The bot posts one of two shapes; try the Monday one first since a single read
window can contain both a stale Friday preview and the current week's Monday
announcement, and the Monday post is the more current of the two:

  Monday announcement: "...time to shine as the Support Hero, <@ID|Name>..."
  followed by "Next week: <@ID|Name>". First mention is week 1, second is week 2.

  Friday preview: "...Next week's Support Hero:...<@ID|Name>" followed by
  "...week after that: <@ID|Name>". First mention is week 1, second is week 2;
  the preceding "finishing up" mention (the outgoing hero) is not week 1 or 2.

The bot itself posts a bare <@ID> mention; slack_read_channel resolves it to
the <@ID|Name> form shown above and in the fixtures below.

Usage: parse-support-hero-message.py < message-text
"""

import json
import re
import sys

MENTION = r"<@(?P<id>[A-Z0-9]+)\|(?P<name>[^>]+)>"


def _week(match):
    # id is unused by SKILL.md today (it matches on name against GitHub
    # handles); kept for a possible future Slack-ID-based match.
    return {"id": match.group("id"), "name": match.group("name")}


def _parse_shape(text, week1_pattern, week2_pattern):
    hero = re.search(week1_pattern + MENTION, text, re.IGNORECASE)
    next_hero = re.search(week2_pattern + MENTION, text, re.IGNORECASE)
    if hero and next_hero:
        return {"week1": _week(hero), "week2": _week(next_hero)}
    return None


def parse_monday(text):
    return _parse_shape(text, r"time to shine as the Support Hero,\s*", r"Next week:\s*")


def parse_friday(text):
    return _parse_shape(text, r"Next week's Support Hero:?\**\s*", r"week after that:\s*")


def parse_message(text):
    return parse_monday(text) or parse_friday(text)


def main():
    result = parse_message(sys.stdin.read())
    print(json.dumps(result) if result else "NOT_FOUND")


if __name__ == "__main__":
    main()
