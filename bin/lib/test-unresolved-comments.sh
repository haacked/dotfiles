#!/bin/bash
# Tests for UNRESOLVED_COMMENTS_JQ, the transform fetch_unresolved_review_comments
# applies to GraphQL reviewThread nodes in copilot.sh.
#
# Usage: test-unresolved-comments.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/copilot.sh
source "$SCRIPT_DIR/copilot.sh"

# Apply the production transform to a JSON array of reviewThread nodes.
transform() {
  jq "$UNRESOLVED_COMMENTS_JQ"
}

# ── Test data ─────────────────────────────────────────────────────────────
# A mix of resolved/unresolved threads, Copilot/human/null authors, a thread
# with no root comment, a null databaseId (a pending review comment), the
# production Copilot bot login, a human handle that contains "copilot", and a
# thread with a reply (only its root should be emitted).

nodes='[
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 1, "path": "src/a.py", "line": 10, "body": "Copilot says fix this", "diffHunk": "@@ -1 +1 @@", "author": {"login": "Copilot"}}
  ]}},
  {"isResolved": true, "comments": {"nodes": [
    {"databaseId": 2, "path": "src/b.py", "line": 20, "body": "resolved already", "diffHunk": "@@", "author": {"login": "Copilot"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 3, "path": "src/c.py", "line": 30, "body": "human nit", "diffHunk": "@@", "author": {"login": "octocat"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": []}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 5, "path": "src/e.py", "line": null, "body": "ghost author", "diffHunk": "@@", "author": null}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 6, "path": "src/f.py", "line": 60, "body": "real bot login", "diffHunk": "@@", "author": {"login": "copilot-pull-request-reviewer"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 7, "path": "src/g.py", "line": 70, "body": "human handle contains copilot", "diffHunk": "@@", "author": {"login": "copilot-fan"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": null, "path": "src/h.py", "line": 80, "body": "pending review comment", "diffHunk": "@@", "author": {"login": "octocat"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 9, "path": "src/i.py", "line": 90, "body": "thread root", "diffHunk": "@@", "author": {"login": "octocat"}},
    {"databaseId": 10, "path": "src/i.py", "line": 90, "body": "a reply", "diffHunk": "@@", "author": {"login": "Copilot"}}
  ]}}
]'

result=$(echo "$nodes" | transform)

# ── Test: only unresolved threads with a non-null root comment id survive ───

count=$(echo "$result" | jq 'length')
assert "keeps 6 of 9 threads (drops resolved, empty-comment, null databaseId)" test "$count" -eq 6

ids=$(echo "$result" | jq -c '[.[].id] | sort')
assert "keeps comment IDs 1, 3, 5, 6, 7, 9" test "$ids" = "[1,3,5,6,7,9]"

# ── Test: null databaseId thread is dropped ────────────────────────────────
# GraphQL returns a null databaseId for a pending (not-yet-submitted) review
# comment; the $c.databaseId != null guard keeps those out of the action list.

has_null_id=$(echo "$result" | jq '[.[] | select(.body == "pending review comment")] | length')
assert "drops thread whose root comment has a null databaseId" test "$has_null_id" -eq 0

# ── Test: only the thread's root comment is emitted, not replies ───────────

has_reply=$(echo "$result" | jq '[.[] | select(.id == 10)] | length')
assert "reply comments are not emitted (id 10 absent)" test "$has_reply" -eq 0
root_body_9=$(echo "$result" | jq -r '.[] | select(.id == 9) | .body')
assert "thread root comment is emitted (id 9 body)" test "$root_body_9" = "thread root"

# ── Test: Copilot authorship detected ──────────────────────────────────────
# is_copilot matches the Copilot reviewer's exact login (case-insensitive), not a
# substring. The "Copilot" fixture (capital C) also pins the case-insensitivity:
# a case-sensitive match would fail this assertion.

is_copilot_1=$(echo "$result" | jq -r '.[] | select(.id == 1) | .is_copilot')
assert "Copilot comment flagged is_copilot=true" test "$is_copilot_1" = "true"

is_copilot_6=$(echo "$result" | jq -r '.[] | select(.id == 6) | .is_copilot')
assert "production bot login flagged is_copilot=true" test "$is_copilot_6" = "true"

# A human handle that merely contains "copilot" is NOT Copilot; their thread must
# stay open like any other human reviewer's.
is_copilot_7=$(echo "$result" | jq -r '.[] | select(.id == 7) | .is_copilot')
assert "human handle containing 'copilot' is not treated as Copilot" test "$is_copilot_7" = "false"

# ── Test: human authorship detected ────────────────────────────────────────

is_copilot_3=$(echo "$result" | jq -r '.[] | select(.id == 3) | .is_copilot')
assert "human comment flagged is_copilot=false" test "$is_copilot_3" = "false"
author_3=$(echo "$result" | jq -r '.[] | select(.id == 3) | .author')
assert "human author login preserved" test "$author_3" = "octocat"

# ── Test: null author falls back to unknown, not Copilot ───────────────────

author_5=$(echo "$result" | jq -r '.[] | select(.id == 5) | .author')
assert "null author becomes 'unknown'" test "$author_5" = "unknown"
is_copilot_5=$(echo "$result" | jq -r '.[] | select(.id == 5) | .is_copilot')
assert "null author is not Copilot" test "$is_copilot_5" = "false"

# ── Test: GraphQL field names mapped to the consumed shape ─────────────────

diff_hunk_1=$(echo "$result" | jq -r '.[] | select(.id == 1) | .diff_hunk')
assert "diffHunk mapped to diff_hunk" test "$diff_hunk_1" = "@@ -1 +1 @@"
path_1=$(echo "$result" | jq -r '.[] | select(.id == 1) | .path')
assert "path preserved" test "$path_1" = "src/a.py"
line_5=$(echo "$result" | jq '.[] | select(.id == 5) | .line')
assert "null line preserved as null" test "$line_5" = "null"

# ── Test: empty input array yields empty output ────────────────────────────

empty=$(echo '[]' | transform | jq 'length')
assert "empty input returns empty output" test "$empty" -eq 0

# ── Results ───────────────────────────────────────────────────────────────

print_results
