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
GH_STUB = SCRIPTS / "gh_stub.py"


@pytest.fixture
def gh(tmp_path):
    """Install the stub `gh` on PATH and expose the calls it recorded.

    See gh_stub.py for the STUB_* knobs each test sets.
    """
    bin_dir = tmp_path / "bin"
    bin_dir.mkdir()
    stub = bin_dir / "gh"
    # Copied rather than symlinked, so the stub still resolves when this
    # directory is deployed read-only into ~/.claude/skills/.
    stub.write_text(GH_STUB.read_text())
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
            # Per-call env, so a second run in one test doesn't inherit the
            # first one's stub settings. Note the STUB_*_CALLS indexes still
            # count GraphQL calls from the start of the test, not the run.
            return subprocess.run(
                [str(script), *args],
                input=stdin,
                capture_output=True,
                text=True,
                env={**self.env, **{k: str(v) for k, v in overrides.items()}},
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
    assert limits_requested(gh.calls) == [100000]


def test_board_fetch_takes_a_large_board_in_one_call(gh):
    """--limit is a ceiling, not a fetch count, so a board far larger than any
    earlier limit still arrives whole without a second request."""
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL=3030)

    assert result.returncode == 0, result.stderr
    assert len(json.loads(result.stdout)) == 3030
    assert len(limits_requested(gh.calls)) == 1


def test_board_fetch_fails_loudly_when_truncated(gh):
    """A board that comes back short is an error, not a partial answer: callers
    read missing items as work that doesn't exist."""
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL=303, STUB_CAP=200, BOARD_FETCH_LIMIT=200)

    assert result.returncode != 0
    assert result.stdout == ""
    assert "200 of 303" in result.stderr


def test_board_fetch_refuses_an_exactly_full_read_without_a_total(gh):
    """Without .totalCount to compare against, a read that exactly fills the
    limit is treated as short rather than accepted as complete."""
    result = gh.run(FETCH_BOARD_ITEMS, STUB_TOTAL="none", STUB_CAP=7, BOARD_FETCH_LIMIT=5)

    assert result.returncode != 0
    assert result.stdout == ""
    assert "of unknown items" in result.stderr


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
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(120))

    assert result.returncode == 0, result.stderr
    assert len(gh.queries) == 3
    assert "item_0:" in gh.queries[0] and "item_49:" in gh.queries[0]
    assert "item_50:" in gh.queries[1] and "item_99:" in gh.queries[1]
    assert "item_100:" in gh.queries[2] and "item_119:" in gh.queries[2]
    assert "item_50:" not in gh.queries[0]


def test_batch_query_merges_every_chunk_into_one_response(gh):
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(120))

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
        BATCH_QUERY, ["title", "title"], stdin=items(120), STUB_FAILED_CALLS="1"
    )

    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)["data"]
    assert "item_0" in data and "item_100" in data
    assert "item_50" not in data
    # The loss is announced, so a short result isn't mistaken for a full one.
    assert "items 50 to 99 did not resolve" in result.stderr
    # Named, not just numbered: two callers drop unresolved items from their
    # output, so a bare range points into an array the reader never sees.
    assert "PostHog/posthog#51" in result.stderr


def test_batch_query_names_the_final_partial_chunk_exactly(gh):
    """The last chunk holds 20 of the 120 items, so its warning has to stop at
    the last real item rather than at the chunk's nominal end."""
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(120), STUB_FAILED_CALLS="2")

    assert result.returncode == 0, result.stderr
    assert "items 100 to 119" in result.stderr


def test_batch_query_sends_one_query_for_exactly_one_chunk(gh):
    """An input that exactly fills a chunk must not emit a trailing empty query."""
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(50))

    assert result.returncode == 0, result.stderr
    assert len(gh.queries) == 1


def test_batch_query_flattens_a_multiline_selection_set(gh):
    """A newline in either selection set would split one query into fragments,
    so both are flattened before the chunk loop reads them line by line."""
    mixed = json.dumps(
        [
            {"owner": "PostHog", "repo": "posthog", "type": "PullRequest", "number": 1},
            {"owner": "PostHog", "repo": "posthog", "type": "Issue", "number": 2},
        ]
    )
    result = gh.run(BATCH_QUERY, ["state\nisDraft", "state\nstateReason"], stdin=mixed)

    assert result.returncode == 0, result.stderr
    assert len(gh.queries) == 1
    assert "pullRequest(number: 1) { state isDraft }" in gh.queries[0]
    assert "issue(number: 2) { state stateReason }" in gh.queries[0]


def test_batch_query_keeps_a_chunks_survivors_when_one_item_fails(gh):
    """One bad item number nulls its own alias and nothing else. gh exits
    non-zero for the whole response, so the keep decision has to come from the
    body or the other 49 items go with it."""
    result = gh.run(BATCH_QUERY, ["title", "title"], stdin=items(50),
                    STUB_PARTIAL_CALLS="0", STUB_NULL_ALIAS="7")

    assert result.returncode == 0, result.stderr
    data = json.loads(result.stdout)["data"]
    assert len(data) == 50 and data["item_7"] is None
    assert data["item_8"]["pullRequest"]["title"] == "PR9"
    assert "did not resolve" not in result.stderr


def test_batch_query_fails_when_every_chunk_fails(gh):
    """Nothing resolving is not the same answer as an empty board, so it fails
    rather than letting an expired token read as "no work"."""
    result = gh.run(
        BATCH_QUERY, ["title", "title"], stdin=items(120), STUB_FAILED_CALLS="0,1,2"
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert "Error: none of the 120 items resolved" in result.stderr
    # The error already names every item, so the per-chunk warnings stay quiet.
    assert "did not resolve" not in result.stderr


def test_batch_query_tolerates_a_total_loss_when_the_caller_opts_in(gh):
    """A caller that would rather report what it knows gets an empty .data and a
    Warning:, which is the vocabulary SKILL.md keys "incomplete" off. Its index
    join reads the absent aliases as null, exactly as it reads a failed chunk."""
    result = gh.run(
        BATCH_QUERY,
        ["--tolerate-total-loss", "title", "title"],
        stdin=items(120),
        STUB_FAILED_CALLS="0,1,2",
    )

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == {"data": {}}
    assert "Warning: none of the 120 items resolved" in result.stderr


def test_batch_query_still_fails_on_a_rate_limit_when_tolerating_total_loss(gh):
    """Opting into a tolerated lookup failure is not opting into spending a quota
    GitHub has stopped allowing, so exit 1 survives the flag."""
    result = gh.run(
        BATCH_QUERY,
        ["--tolerate-total-loss", "title", "title"],
        stdin=items(120),
        STUB_RATE_LIMITED_CALLS="0",
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()


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
        STUB_RATE_LIMITED_CALLS="1",
        STUB_RATE_LIMIT_MODE="body",
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()
    # The position is the only thing naming where the run stopped.
    assert "at item 50" in result.stderr
    assert len(gh.queries) == 2  # stopped at the failing chunk


def test_batch_query_fails_on_a_secondary_rate_limit(gh):
    """A secondary limit is a 403 whose body is a bare message with no .errors
    array, so the body check has to look at both shapes."""
    result = gh.run(
        BATCH_QUERY,
        ["title", "title"],
        stdin=items(120),
        STUB_RATE_LIMITED_CALLS="1",
        STUB_RATE_LIMIT_MODE="secondary",
    )

    assert result.returncode == 1
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()
    assert len(gh.queries) == 2  # stopped at the failing chunk


def test_batch_query_fails_on_a_rate_limit_reported_only_on_stderr(gh):
    result = gh.run(
        BATCH_QUERY,
        ["title", "title"],
        stdin=items(120),
        STUB_RATE_LIMITED_CALLS="0",
        STUB_RATE_LIMIT_MODE="stderr",
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()


# --- caller contract ---


def test_board_goals_sees_active_items_past_the_first_fetch(gh):
    """The reported bug: active work sitting beyond the old 200-item cap never
    reached the sprint plan, because the status filter runs after the fetch."""
    result = gh.run(FETCH_BOARD_GOALS, STUB_TOTAL=303)

    assert result.returncode == 0, result.stderr
    goals = json.loads(result.stdout)
    # Every status but Done, across the whole board rather than its first 200.
    # The stub cycles five statuses, so every fifth item is the Done one.
    assert len(goals) == 303 - len(range(0, 303, 5))
    assert {g["title"] for g in goals} >= {"T201", "T302"}
    assert not any(g["status"] == "Done" for g in goals)
    # Assignees come off the board listing, so each item keeps its own.
    assert all(g["assignees"] == [f"user{g['number']}"] for g in goals)
    # And no follow-up query is needed to learn them.
    assert gh.queries == []


def test_board_goals_projects_drafts_and_unassigned_items(gh):
    """A draft card has no linked Issue or PR, so url, type and number stay null
    rather than erroring on tonumber. An unassigned item omits the key."""
    result = gh.run(FETCH_BOARD_GOALS, STUB_TOTAL=5,
                    STUB_DRAFT_ITEMS="1", STUB_UNASSIGNED_ITEMS="3")

    assert result.returncode == 0, result.stderr
    by_id = {g["id"]: g for g in json.loads(result.stdout)}
    assert by_id["i1"]["url"] is None and by_id["i1"]["number"] is None
    assert by_id["i3"]["assignees"] == []


def test_resolve_item_status_keeps_urls_when_nothing_resolves(gh):
    """The documented degrade path: this caller passes --tolerate-total-loss, so
    a query that resolves nothing still returns the URLs with null state rather
    than an empty array that reads as a plan referencing nothing. The Warning: is
    what tells the agent the states are unknown rather than genuinely absent."""
    urls = "\n".join(f"https://github.com/PostHog/posthog/pull/{n}" for n in range(1, 4))
    result = gh.run(RESOLVE_ITEM_STATUS, stdin=urls, STUB_FAILED_CALLS="0")

    assert result.returncode == 0, result.stderr
    resolved = json.loads(result.stdout)
    assert len(resolved) == 3
    assert all(item["state"] is None and item["url"] for item in resolved)
    assert "Warning: none of the 3 items resolved" in result.stderr


def test_resolve_item_status_still_aborts_on_a_rate_limit(gh):
    """A tolerated lookup failure is not a tolerated quota failure. Papering over
    an exhausted limit would report a whole plan as unknown."""
    urls = "\n".join(f"https://github.com/PostHog/posthog/pull/{n}" for n in range(1, 4))
    result = gh.run(RESOLVE_ITEM_STATUS, stdin=urls, STUB_RATE_LIMITED_CALLS="0")

    assert result.returncode == 1
    assert result.stdout == ""
    assert "rate limit" in result.stderr.lower()


def test_approved_prs_aborts_when_nothing_resolves(gh):
    """A total failure must not print [], which reads as "you approved nothing"
    and silently drops every PR from the sprint plan."""
    result = gh.run(FETCH_APPROVED_PRS, stdin="", STUB_SEARCH_PRS=3, STUB_FAILED_CALLS="0")

    assert result.returncode != 0
    assert result.stdout == ""
    assert "none of the 3 items resolved" in result.stderr


def test_archive_aborts_rather_than_reporting_a_truncated_board(gh):
    """A short board must stop the caller. Returning the items it did see would
    read as "nothing left to archive" and leave stale items on the board."""
    result = gh.run(
        ARCHIVE_DONE_ITEMS, ["2026-08-01"], STUB_TOTAL=303, STUB_CAP=200, BOARD_FETCH_LIMIT=200
    )

    assert result.returncode != 0
    assert result.stdout == ""
    assert "truncated board" in result.stderr


def test_archive_lists_done_items_closed_before_the_sprint(gh):
    """Happy path: Done items merged before the sprint start are archive
    candidates. Nothing else runs archive-done-items.sh to completion, so
    without this the board projection and the date join are both unexercised."""
    result = gh.run(ARCHIVE_DONE_ITEMS, ["2026-08-01"], STUB_TOTAL=10)

    assert result.returncode == 0, result.stderr
    candidates = json.loads(result.stdout)
    # The stub cycles five statuses, so items 0 and 5 are the Done ones.
    assert {c["number"] for c in candidates} == {0, 5}
    assert all(c["closed_date"] == "2026-07-15" for c in candidates)


def test_archive_skips_items_closed_after_the_sprint_started(gh):
    """An item closed during the sprint is this sprint's work, not stale."""
    result = gh.run(ARCHIVE_DONE_ITEMS, ["2026-07-01"], STUB_TOTAL=10)

    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == []


def test_approved_prs_drops_unresolved_prs_instead_of_failing(gh):
    """A chunk that fails leaves its PRs with no reviews to judge; the caller
    reports the ones it could resolve rather than dying on a null node."""
    result = gh.run(
        FETCH_APPROVED_PRS, stdin="", STUB_SEARCH_PRS=60, STUB_FAILED_CALLS="1"
    )

    assert result.returncode == 0, result.stderr
    approved = json.loads(result.stdout)
    assert len(approved) == 50
    assert {pr["number"] for pr in approved} == set(range(1, 51))


def test_chunking_keeps_a_callers_index_join_aligned(gh):
    """resolve-item-status.sh joins the response back by index; with more items
    than fit in a chunk, every URL must still get its own item's data."""
    urls = "\n".join(f"https://github.com/PostHog/posthog/pull/{n}" for n in range(1, 61))
    result = gh.run(RESOLVE_ITEM_STATUS, stdin=urls)

    assert result.returncode == 0, result.stderr
    resolved = json.loads(result.stdout)
    assert len(resolved) == 60
    assert all(item["title"] == f"PR{item['number']}" for item in resolved)
