"""Tests for support-hero-window.py's midnight-anchored epoch window."""

import importlib.util
from datetime import datetime
from pathlib import Path

_spec = importlib.util.spec_from_file_location(
    "support_hero_window", Path(__file__).resolve().parent / "support-hero-window.py"
)
assert _spec is not None and _spec.loader is not None
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
window_bounds = _mod.window_bounds


def local_midnight(y, m, d):
    return int(datetime(y, m, d).timestamp())


def test_window_covers_the_friday_before_through_the_monday_itself():
    # Verified live against Slack: the sprint's own Monday announcement for
    # 2026-09-07 sits inside this window.
    oldest, latest = window_bounds("2026-09-07")
    assert oldest == local_midnight(2026, 9, 4)  # 3 days before sprint_start
    assert latest == local_midnight(2026, 9, 8)  # the day after sprint_start


def test_window_crosses_month_boundary():
    oldest, latest = window_bounds("2026-10-05")
    assert oldest == local_midnight(2026, 10, 2)
    assert latest == local_midnight(2026, 10, 6)
