"""Tests for the board-fetch and batched-query shell helpers.

Every test drives the scripts through a stub `gh` placed first on PATH, so the
suite exercises pagination, chunking and failure handling without touching the
GitHub API. The stub records each invocation it receives, which is how the
tests assert on the queries the scripts actually built.
"""

import json
import os
import subprocess
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).resolve().parent
FETCH_BOARD_ITEMS = SCRIPTS / "fetch-board-items.sh"
BATCH_QUERY = SCRIPTS / "batch-item-query.sh"
RESOLVE_ITEM_STATUS = SCRIPTS / "resolve-item-status.sh"
FETCH_APPROVED_PRS = SCRIPTS / "fetch-approved-prs.sh"
ARCHIVE_DONE_ITEMS = SCRIPTS / "archive-done-items.sh"
FETCH_BOARD_GOALS = SCRIPTS / "fetch-board-goals.sh"

# Stub `gh`. Board fetches return STUB_TOTAL as .totalCount (omitted when set to
# "none") and min(--limit, STUB_CAP) items, so a cap below the total simulates a
# board that stays truncated however high the limit goes. GraphQL calls echo one
# node per item_<idx> alias in the query, titled after the item's number so
# callers' index joins can be checked for alignment.
GH_STUB = r'''#!/usr/bin/env python3
import json, os, re, sys

argv = sys.argv[1:]
log = os.environ["STUB_LOG"]
with open(log, "a") as fh:
    fh.write(json.dumps(argv) + "\n")

if argv[:2] == ["project", "item-list"]:
    limit = int(argv[argv.index("--limit") + 1])
    total = os.environ.get("STUB_TOTAL", "0")
    cap = int(os.environ.get("STUB_CAP", "100000"))
    returned = min(limit, cap if total == "none" else min(cap, int(total)))
    statuses = ["Done", "In Progress", "In Review", "Todo", "Approved"]
    out = {"items": [
        {
            "id": f"i{n}",
            "title": f"T{n}",
            "status": statuses[n % len(statuses)],
            "content": {
                "url": f"https://github.com/PostHog/posthog/pull/{n}",
                "type": "PullRequest",
                "number": n,
                "repository": "PostHog/posthog",
            },
        }
        for n in range(returned)
    ]}
    if total != "none":
        out["totalCount"] = int(total)
    print(json.dumps(out))
    sys.exit(0)

if argv[:2] == ["api", "user"]:
    print("stubuser")
    sys.exit(0)

if argv[:2] == ["search", "prs"]:
    count = int(os.environ.get("STUB_SEARCH_PRS", "0"))
    print(json.dumps([
        {
            "number": n,
            "title": f"PR{n}",
            "url": f"https://github.com/PostHog/posthog/pull/{n}",
            "repository": {"name": "posthog", "nameWithOwner": "PostHog/posthog"},
            "isDraft": False,
            "updatedAt": "2026-08-01T00:00:00Z",
        }
        for n in range(1, count + 1)
    ]))
    sys.exit(0)

if argv[:2] == ["api", "graphql"]:
    query = next(a.split("=", 1)[1] for a in argv if a.startswith("query="))
    prior = [json.loads(line) for line in open(log)][:-1]
    call_number = sum(1 for c in prior if c[:2] == ["api", "graphql"])

    if str(call_number) in os.environ.get("STUB_RATE_LIMITED_CALLS", "").split(","):
        mode = os.environ.get("STUB_RATE_LIMIT_MODE", "body")
        if mode == "body":
            print(json.dumps({"errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}))
        else:
            print("gh: API rate limit exceeded for user ID 1", file=sys.stderr)
        sys.exit(1)

    if str(call_number) in os.environ.get("STUB_FAILED_CALLS", "").split(","):
        print(json.dumps({"errors": [{"message": "Something went wrong"}]}))
        sys.exit(1)

    data = {}
    for idx, kind, number in re.findall(
        r'item_(\d+): repository\([^)]*\) \{ (pullRequest|issue)\(number: (\d+)\)', query
    ):
        if kind == "pullRequest":
            data[f"item_{idx}"] = {"pullRequest": {
                "state": "OPEN",
                "isDraft": False,
                "title": f"PR{number}",
                "assignees": {"nodes": [{"login": f"user{number}"}]},
                "author": {"login": "someone"},
                "latestOpinionatedReviews": {"nodes": [{"author": {"login": "stubuser"}, "state": "APPROVED"}]},
            }}
        else:
            data[f"item_{idx}"] = {"issue": {"state": "CLOSED", "stateReason": "COMPLETED", "title": f"IS{number}"}}
    print(json.dumps({"data": data}))
    sys.exit(0)

print(f"unexpected gh invocation: {argv}", file=sys.stderr)
sys.exit(1)
'''


@pytest.fixture
def gh(tmp_path):
    """Install the stub `gh` on PATH and expose the calls it recorded."""
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "gh"
    stub.write_text(GH_STUB)
    stub.chmod(0o755)
    log = tmp_path / "gh-calls.log"
    log.touch()

    env = dict(os.environ)
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    env["STUB_LOG"] = str(log)

    class Gh:
        def __init__(self):
            self.env = env

        def run(self, script, args=(), stdin=None, **overrides):
            self.env.update({k: str(v) for k, v in overrides.items()})
            return subprocess.run(
                [str(script), *args],
                input=stdin,
                capture_output=True,
                text=True,
                env=self.env,
            )

        @property
        def calls(self):
            return [json.loads(line) for line in log.read_text().splitlines()]

        @property
        def queries(self):
            return [
                next(a.split("=", 1)[1] for a in call if a.startswith("query="))
                for call in self.calls
                if call[:2] == ["api", "graphql"]
            ]

    return Gh()


def limits_requested(calls):
    return [int(c[c.index("--limit") + 1]) for c in calls if c[:2] == ["project", "item-list"]]


# --- fetch-board-items.sh ---


def test_board_fetch_returns_every_item_in_one_call(gh):
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL=5)

    assert result.returncode == 0, result.stderr
    assert len(json.loads(result.stdout)) == 5
    assert limits_requested(gh.calls) == [1000]


def test_board_fetch_retries_when_the_board_exceeds_the_limit(gh):
    """A board larger than the starting limit is refetched, not truncated."""
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL=303, SPRINT_BOARD_FETCH_LIMIT=200)

    assert result.returncode == 0, result.stderr
    assert len(json.loads(result.stdout)) == 303
    first, second = limits_requested(gh.calls)
    assert first == 200
    assert second >= 303


def test_board_fetch_fails_loudly_when_still_truncated(gh):
    """A board that stays short however high the limit goes is an error, not a
    partial answer: callers read missing items as work that doesn't exist."""
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL=303, STUB_CAP=200, SPRINT_BOARD_FETCH_LIMIT=200)

    assert result.returncode != 0
    assert result.stdout == ""
    assert "200 of 303" in result.stderr


def test_board_fetch_retries_an_exactly_full_read_without_a_total(gh):
    """Without .totalCount to compare against, a read that exactly fills the
    limit is treated as short rather than accepted as complete."""
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL="none", STUB_CAP=7, SPRINT_BOARD_FETCH_LIMIT=5)

    assert result.returncode == 0, result.stderr
    assert len(json.loads(result.stdout)) == 7
    assert len(limits_requested(gh.calls)) == 2


# --- batch-item-query.sh ---


def items(count, kind="PullRequest", start=1):
    return json.dumps(
        [
            {"owner": "PostHog", "repo": "posthog", "type": kind, "number": start + n}
            for n in range(count)
        ]
    )


def test_batch_query_chunks_and_indexes_aliases_globally(gh):
    """Callers join by index against the full input, so aliases must count from
    the start of the input rather than restart in each chunk."""
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(120), BATCH_ITEM_CHUNK_SIZE=50)

    assert result.returncode == 0, result.stderr
    assert len(gh.queries) == 3
    assert "item_0:" in gh.queries[0] and "item_49:" in gh.queries[0]
    assert "item_50:" in gh.queries[1] and "item_99:" in gh.queries[1]
    assert "item_100:" in gh.queries[2] and "item_119:" in gh.queries[2]
    assert "item_50:" not in gh.queries[0]


def test_batch_query_merges_every_chunk_into_one_response(gh):
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(120), BATCH_ITEM_CHUNK_SIZE=50)

    data = json.loads(result.stdout)["data"]
    assert len(data) == 120
    # item_<idx> holds the item at that position in the input, numbered from 1.
    assert data["item_0"]["pullRequest"]["title"] == "PR1"
    assert data["item_119"]["pullRequest"]["title"] == "PR120"


def test_batch_query_routes_issues_and_prs_to_their_own_fields(gh):
    mixed = json.dumps(
        [
            {"owner": "PostHog", "repo": "posthog", "type": "PullRequest", "number": 1},
            {"owner": "PostHog", "repo": "posthog", "type": "Issue", "number": 2},
        ]
    )
    result = gh.run(BATCH_QUERY, ["state isDraft", "state stateReason"], stdin=mixed)

    assert "pullRequest(number: 1) { state isDraft }" in gh.queries[0]
    assert "issue(number: 2) { state stateReason }" in gh.queries[0]
    data = json.loads(result.stdout)["data"]
    assert data["item_0"]["pullRequest"]["state"] == "OPEN"
    assert data["item_1"]["issue"]["stateReason"] == "COMPLETED"


def test_batch_query_keeps_surviving_chunks_when_one_fails(gh):
    """A failed chunk leaves its items absent, which callers read as null, while
    the rest of the board still resolves."""
    result = gh.run(
        BATCH_QUERY, ["title", "title"], stdin=items(120), BATCH_ITEM_CHUNK_SIZE=50, STUB_FAILED_CALLS="1"
    )

    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)["data"]
    assert "item_0" in data and "item_100" in data
    assert "item_50" not in data


def test_batch_query_prints_nothing_when_every_chunk_fails(gh):
    result = gh.run(
        BATCH_QUERY, ["title", "title"], stdin=items(120), BATCH_ITEM_CHUNK_SIZE=50, STUB_FAILED_CALLS="0,1,2"
    )

    assert result.returncode == 0, result.stderr
    assert result.stdout == ""


def test_batch_query_prints_nothing_for_empty_input(gh):
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin="[]")

    assert result.returncode == 0, result.stderr
    assert result.stdout == ""
    assert gh.queries == []


def test_batch_query_fails_on_a_rate_limit_error_in_the_body(gh):
    """Quota exhaustion must not read as "no items": it stops the run instead."""
    result = gh.run(
        BATCH_QUERY,
        ["title", "title"],
        stdin=items(120),
        BATCH_ITEM_CHUNK_SIZE=50,
        STUB_RATE_LIMITED_CALLS="1",
        STUB_RATE_LIMIT_MODE="body",
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()
    assert len(gh.queries) == 2  # stopped at the failing chunk


def test_batch_query_fails_on_a_rate_limit_reported_only_on_stderr(gh):
    result = gh.run(
        BATCH_QUERY,
        ["title", "title"],
        stdin=items(120),
        BATCH_ITEM_CHUNK_SIZE=50,
        STUB_RATE_LIMITED_CALLS="0",
        STUB_RATE_LIMIT_MODE="stderr",
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()


# --- caller contract ---


def test_board_goals_sees_active_items_past_the_first_fetch(gh):
    """The reported bug: active work sitting beyond the fetch limit never
    reached the sprint plan, because the status filter runs after the fetch."""
    result = gh.run(
        FETCH_BOARD_GOALS, STUB_TOTAL=303, SPRINT_BOARD_FETCH_LIMIT=200, BATCH_ITEM_CHUNK_SIZE=50
    )

    assert result.returncode == 0, result.stderr
    goals = json.loads(result.stdout)
    # Every status but Done, across the whole board rather than its first 200.
    assert len(goals) == 242
    assert {g["title"] for g in goals} >= {"T201", "T302"}
    assert not any(g["status"] == "Done" for g in goals)
    # Assignees stay joined to their own item across chunk boundaries.
    assert all(g["assignees"] == [f"user{g['number']}"] for g in goals)


def test_archive_aborts_rather_than_reporting_a_truncated_board(gh):
    """A short board must stop the caller. Returning the items it did see would
    read as "nothing left to archive" and leave stale items on the board."""
    result = gh.run(
        ARCHIVE_DONE_ITEMS, ["2026-08-01"], STUB_TOTAL=303, STUB_CAP=200, SPRINT_BOARD_FETCH_LIMIT=200
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "truncated board" in result.stderr


def test_approved_prs_drops_unresolved_prs_instead_of_failing(gh):
    """A chunk that fails leaves its PRs with no reviews to judge; the caller
    reports the ones it could resolve rather than dying on a null node."""
    result = gh.run(
        FETCH_APPROVED_PRS, stdin="", STUB_SEARCH_PRS=60, BATCH_ITEM_CHUNK_SIZE=50, STUB_FAILED_CALLS="1"
    )

    assert result.returncode == 0, result.stderr
    approved = json.loads(result.stdout)
    assert len(approved) == 50
    assert {pr["number"] for pr in approved} == set(range(1, 51))


def test_chunking_keeps_a_callers_index_join_aligned(gh):
    """resolve-item-status.sh joins the response back by index; with more items
    than fit in a chunk, every URL must still get its own item's data."""
    urls = "\n".join(f"https://github.com/PostHog/posthog/pull/{n}" for n in range(1, 61))
    result = gh.run(RESOLVE_ITEM_STATUS, stdin=urls, BATCH_ITEM_CHUNK_SIZE=50)

    assert result.returncode == 0, result.stderr
    resolved = json.loads(result.stdout)
    assert len(resolved) == 60
    assert all(item["title"] == f"PR{item['number']}" for item in resolved)
