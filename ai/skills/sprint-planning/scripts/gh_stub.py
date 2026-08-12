#!/usr/bin/env python3
"""Stub `gh` for test_board_scripts.py, copied onto PATH by that file's fixture.

Every invocation is appended to STUB_LOG as a JSON array, which is how the tests
assert on the queries the scripts actually built.

Board fetches return STUB_TOTAL as .totalCount (omitted when set to "none") and
min(--limit, STUB_CAP, STUB_TOTAL) items, or min(--limit, STUB_CAP) when
STUB_TOTAL is "none", so a cap below the total simulates a board that stays
truncated however high the limit goes. STUB_CLOSED_AT is the mergedAt/closedAt
every resolved item carries. STUB_DRAFT_ITEMS and
STUB_UNASSIGNED_ITEMS are comma-separated item indexes: a draft gets DraftIssue
content with no url or number, and an unassigned item omits the assignees key
entirely, which is what the real CLI does.

GraphQL calls echo one node per item_<idx> alias in the query, titled after the
item's number so callers' index joins can be checked for alignment.
STUB_FAILED_CALLS, STUB_RATE_LIMITED_CALLS and STUB_PARTIAL_CALLS are
comma-separated, zero-based GraphQL call numbers, so "1" affects the second chunk
rather than the second item:

  STUB_FAILED_CALLS       whole chunk fails with no .data
  STUB_RATE_LIMITED_CALLS chunk hits a rate limit, shaped by STUB_RATE_LIMIT_MODE:
                          "body" puts a RATE_LIMITED entry under .errors,
                          "secondary" returns a bare 403 {"message": ...} with no
                          .errors array, "stderr" prints only gh's summary line
  STUB_PARTIAL_CALLS      chunk returns .data alongside .errors and exits
                          non-zero, nulling the one alias named by STUB_NULL_ALIAS

STUB_SEARCH_PRS is how many PRs `gh search prs` returns.
"""

import json
import os
import re
import sys

CLOSED_AT = os.environ.get("STUB_CLOSED_AT", "2026-07-15T00:00:00Z")

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
    drafts = {int(x) for x in os.environ.get("STUB_DRAFT_ITEMS", "").split(",") if x}
    unassigned = {int(x) for x in os.environ.get("STUB_UNASSIGNED_ITEMS", "").split(",") if x}
    out = {"items": [
        {
            "id": f"i{n}",
            "title": f"T{n}",
            "status": statuses[n % len(statuses)],
            **({} if n in unassigned else {"assignees": [f"user{n}"]}),
            "content": ({"type": "DraftIssue", "title": f"T{n}", "body": ""} if n in drafts else {
                "url": f"https://github.com/PostHog/posthog/pull/{n}",
                "type": "PullRequest",
                "number": n,
                "repository": "PostHog/posthog",
            }),
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
    # Drop this invocation's own line, so the count is this call's zero-based number.
    with open(log) as fh:
        prior = [json.loads(line) for line in fh][:-1]
    call_number = sum(1 for c in prior if c[:2] == ["api", "graphql"])

    if str(call_number) in os.environ.get("STUB_RATE_LIMITED_CALLS", "").split(","):
        mode = os.environ.get("STUB_RATE_LIMIT_MODE", "body")
        if mode == "body":
            print(json.dumps({"errors": [{"type": "RATE_LIMITED", "message": "API rate limit exceeded"}]}))
        elif mode == "secondary":
            print(json.dumps({"message": "You have exceeded a secondary rate limit", "status": "403"}))
        else:
            print("gh: API rate limit exceeded for user ID 1", file=sys.stderr)
        sys.exit(1)

    if str(call_number) in os.environ.get("STUB_FAILED_CALLS", "").split(","):
        print(json.dumps({"errors": [{"message": "Something went wrong"}]}))
        sys.exit(1)

    partial = str(call_number) in os.environ.get("STUB_PARTIAL_CALLS", "").split(",")
    null_alias = os.environ.get("STUB_NULL_ALIAS", "")
    data = {}
    for idx, kind, number in re.findall(
        r'item_(\d+): repository\([^)]*\) \{ (pullRequest|issue)\(number: (\d+)\)', query
    ):
        if partial and idx == null_alias:
            data[f"item_{idx}"] = None
            continue
        if kind == "pullRequest":
            data[f"item_{idx}"] = {"pullRequest": {
                "state": "OPEN",
                "isDraft": False,
                "title": f"PR{number}",
                "author": {"login": "someone"},
                "mergedAt": CLOSED_AT,
                "closedAt": CLOSED_AT,
                "latestOpinionatedReviews": {"nodes": [{"author": {"login": "stubuser"}, "state": "APPROVED"}]},
            }}
        else:
            data[f"item_{idx}"] = {"issue": {
                "state": "CLOSED",
                "stateReason": "COMPLETED",
                "title": f"IS{number}",
                "closedAt": CLOSED_AT,
            }}
    body = {"data": data}
    if partial:
        body["errors"] = [{"type": "NOT_FOUND", "message": "Could not resolve to a PullRequest"}]
    print(json.dumps(body))
    sys.exit(1 if partial else 0)

print(f"unexpected gh invocation: {argv}", file=sys.stderr)
sys.exit(1)
