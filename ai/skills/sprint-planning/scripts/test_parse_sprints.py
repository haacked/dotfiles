"""Tests for parse-sprints.py date parsing and sprint selection logic."""

from datetime import date

import importlib

# The module uses a hyphenated filename which isn't directly importable.
_mod = importlib.import_module("parse-sprints")
parse_date = _mod.parse_date
parse_sprint_dates = _mod.parse_sprint_dates
select_sprints = _mod.select_sprints
sprint_to_tsv = _mod.sprint_to_tsv


# --- parse_date ---


def test_parse_date_abbreviated_month():
    assert parse_date("Feb 23", 2026) == date(2026, 2, 23)


def test_parse_date_full_month():
    assert parse_date("March 8", 2026) == date(2026, 3, 8)


def test_parse_date_explicit_year_takes_precedence():
    assert parse_date("Feb 23 2026", 2099) == date(2026, 2, 23)


def test_parse_date_returns_none_for_garbage():
    assert parse_date("not a date", 2026) is None


# --- parse_sprint_dates ---


def test_parse_sprint_dates_same_month():
    start, end = parse_sprint_dates("Sprint - Feb 10 to Feb 23", date(2026, 2, 15))
    assert start == date(2026, 2, 10)
    assert end == date(2026, 2, 23)


def test_parse_sprint_dates_cross_month():
    start, end = parse_sprint_dates("Sprint - Feb 23 to March 8", date(2026, 2, 25))
    assert start == date(2026, 2, 23)
    assert end == date(2026, 3, 8)


def test_parse_sprint_dates_dec_to_jan_from_january():
    """When today is in January, a Dec-to-Jan title should resolve to the
    preceding December, not December of the current year."""
    start, end = parse_sprint_dates("Sprint - Dec 30 to Jan 13", date(2026, 1, 5))
    assert start == date(2025, 12, 30)
    assert end == date(2026, 1, 13)


def test_parse_sprint_dates_dec_to_jan_from_december():
    """When today is in December, the sprint should resolve to the current year."""
    start, end = parse_sprint_dates("Sprint - Dec 30 to Jan 13", date(2025, 12, 31))
    assert start == date(2025, 12, 30)
    assert end == date(2026, 1, 13)


def test_parse_sprint_dates_non_matching_title():
    start, end = parse_sprint_dates("Not a sprint title", date(2026, 2, 15))
    assert start is None
    assert end is None


def test_parse_sprint_dates_case_insensitive():
    start, end = parse_sprint_dates("sprint - Feb 10 to Feb 23", date(2026, 2, 15))
    assert start == date(2026, 2, 10)
    assert end == date(2026, 2, 23)


# --- select_sprints ---


def test_select_sprints_exact_match():
    sprints = [
        {"number": 10, "title": "Sprint - Feb 10 to Feb 23"},
        {"number": 9, "title": "Sprint - Jan 27 to Feb 9"},
    ]
    current, prev = select_sprints(sprints, date(2026, 2, 15))
    assert current["number"] == 10
    assert prev["number"] == 9


def test_select_sprints_between_sprints_picks_most_recent_past():
    """When today falls in a gap between sprints, pick the one whose start
    date is nearest but still on or before today."""
    sprints = [
        {"number": 10, "title": "Sprint - Feb 10 to Feb 23"},
        {"number": 11, "title": "Sprint - Feb 27 to Mar 12"},
    ]
    current, prev = select_sprints(sprints, date(2026, 2, 25))
    assert current["number"] == 10
    assert prev is None


def test_select_sprints_all_future_picks_nearest():
    """When all sprints are in the future, select the one with the nearest
    start date, not the furthest."""
    sprints = [
        {"number": 1, "title": "Sprint - Feb 10 to Feb 23"},
        {"number": 2, "title": "Sprint - Feb 24 to Mar 9"},
    ]
    current, prev = select_sprints(sprints, date(2026, 1, 1))
    assert current["number"] == 1


def test_select_sprints_empty_list():
    current, prev = select_sprints([], date(2026, 2, 15))
    assert current is None
    assert prev is None


def test_select_sprints_single_sprint_has_no_previous():
    sprints = [{"number": 1, "title": "Sprint - Feb 10 to Feb 23"}]
    current, prev = select_sprints(sprints, date(2026, 2, 15))
    assert current["number"] == 1
    assert prev is None


# --- sprint_to_tsv ---


def test_sprint_to_tsv_with_sprint():
    sprint = {
        "number": 10,
        "title": "Sprint - Feb 10 to Feb 23",
        "start": date(2026, 2, 10),
        "end": date(2026, 2, 23),
    }
    assert sprint_to_tsv(sprint) == "10\tSprint - Feb 10 to Feb 23\t2026-02-10\t2026-02-23"


def test_sprint_to_tsv_with_none():
    assert sprint_to_tsv(None) == "NOT_FOUND\tNOT_FOUND\tNOT_FOUND\tNOT_FOUND"
