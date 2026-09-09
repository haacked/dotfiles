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

Usage: parse-support-hero-message.py < message-text
"""

import json
import re
import sys

MENTION = r"<@(?P<id>[A-Z0-9]+)\|(?P<name>[^>]+)>"


def _week(match):
    return {"id": match.group("id"), "name": match.group("name")}


def parse_monday(text):
    hero = re.search(r"time to shine as the Support Hero,\s*" + MENTION, text)
    next_hero = re.search(r"Next week:\s*" + MENTION, text)
    if hero and next_hero:
        return {"week1": _week(hero), "week2": _week(next_hero)}
    return None


def parse_friday(text):
    hero = re.search(r"Next week's Support Hero:?\**\s*" + MENTION, text, re.IGNORECASE)
    next_hero = re.search(r"week after that:\s*" + MENTION, text, re.IGNORECASE)
    if hero and next_hero:
        return {"week1": _week(hero), "week2": _week(next_hero)}
    return None


def parse_message(text):
    return parse_monday(text) or parse_friday(text)


def main():
    result = parse_message(sys.stdin.read())
    print(json.dumps(result) if result else "NOT_FOUND")


if __name__ == "__main__":
    main()
