"""Tests for parse-support-hero-message.py's bot-message shape matching."""

import importlib.util
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "parse_support_hero_message", Path(__file__).resolve().parent / "parse-support-hero-message.py"
)
assert _spec is not None and _spec.loader is not None
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
parse_message = _mod.parse_message

# Captured verbatim from #team-feature-flags via slack_read_channel.
MONDAY_TEXT = """*It's your time to shine as the Support Hero, <@U07M8N3K8EA|Patricio>!*
Next week: <@U086UNZDP37|haacked>
<https://github.com/PostHog/shared-actions/blob/main/support-hero-notification/teams.yml|:gear: View/Edit rotation config>"""

# Also captured verbatim, from the same channel 3 days earlier.
FRIDAY_TEXT = """<@U09V3PXHZCL|matheus> is finishing up their Support Hero shift.
*Next week's Support Hero:*
<@U07M8N3K8EA|Patricio>
The week after that: <@U086UNZDP37|haacked>
<https://github.com/PostHog/shared-actions/blob/main/support-hero-notification/teams.yml|:gear: View/Edit rotation config>"""


def test_parses_monday_announcement():
    result = parse_message(MONDAY_TEXT)
    assert result == {
        "week1": {"id": "U07M8N3K8EA", "name": "Patricio"},
        "week2": {"id": "U086UNZDP37", "name": "haacked"},
    }


def test_parses_friday_preview_skipping_outgoing_hero():
    result = parse_message(FRIDAY_TEXT)
    assert result == {
        "week1": {"id": "U07M8N3K8EA", "name": "Patricio"},
        "week2": {"id": "U086UNZDP37", "name": "haacked"},
    }


def test_prefers_monday_shape_when_both_present_in_one_window():
    # Monday is preferred as the more current of the two, e.g. after a weekend shift swap.
    swapped_friday = FRIDAY_TEXT.replace("Patricio", "SomeoneElse")
    combined = swapped_friday + "\n\n" + MONDAY_TEXT
    result = parse_message(combined)
    assert result == {
        "week1": {"id": "U07M8N3K8EA", "name": "Patricio"},
        "week2": {"id": "U086UNZDP37", "name": "haacked"},
    }


def test_returns_none_for_unrelated_text():
    assert parse_message("just a regular standup message, nothing to see here") is None
