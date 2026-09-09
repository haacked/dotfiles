"""Tests for support-hero-window.py's midnight-anchored epoch window."""

import importlib.util
import os
import time
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import pytest

_spec = importlib.util.spec_from_file_location(
    "support_hero_window", Path(__file__).resolve().parent / "support-hero-window.py"
)
assert _spec is not None and _spec.loader is not None
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
window_bounds = _mod.window_bounds

# window_bounds interprets its dates in the process timezone. Pinning it to a
# non-UTC zone here, rather than reusing window_bounds's own formula for the
# expected value, is what lets these tests catch a timezone-handling
# regression instead of trivially agreeing with the source under any TZ.
_TZ = "Pacific/Auckland"


@pytest.fixture(autouse=True)
def _pinned_timezone():
    original = os.environ.get("TZ")
    os.environ["TZ"] = _TZ
    time.tzset()
    yield
    if original is None:
        os.environ.pop("TZ", None)
    else:
        os.environ["TZ"] = original
    time.tzset()


def _utc_midnight(y, m, d):
    return datetime(y, m, d, tzinfo=ZoneInfo(_TZ)).astimezone(timezone.utc)


def test_window_covers_the_friday_before_through_the_monday_itself():
    # Verified live against Slack: the sprint's own Monday announcement for
    # 2026-09-07 sits inside this window.
    oldest, latest = window_bounds("2026-09-07")
    assert datetime.fromtimestamp(oldest, timezone.utc) == _utc_midnight(2026, 9, 4)  # 3 days before sprint_start
    assert datetime.fromtimestamp(latest, timezone.utc) == _utc_midnight(2026, 9, 8)  # the day after sprint_start


def test_window_crosses_month_boundary():
    oldest, latest = window_bounds("2026-10-05")
    assert datetime.fromtimestamp(oldest, timezone.utc) == _utc_midnight(2026, 10, 2)
    assert datetime.fromtimestamp(latest, timezone.utc) == _utc_midnight(2026, 10, 6)
