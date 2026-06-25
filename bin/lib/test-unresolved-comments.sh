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
# A mix of resolved/unresolved threads and authors that exercise the is_bot gate:
# a Copilot comment with no __typename (must fall back to the login check), the
# production Copilot bot login typed as "Bot", a non-Copilot bot (Greptile) typed
# as "Bot", a human, a human whose handle contains "copilot", and a null author.
# Plus a thread with no root comment, a null databaseId (a pending review comment),
# and a thread with a reply (only its root should be emitted).

nodes='[
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 1, "path": "src/a.py", "line": 10, "body": "Copilot says fix this", "diffHunk": "@@ -1 +1 @@", "author": {"login": "Copilot"}}
  ]}},
  {"isResolved": true, "comments": {"nodes": [
    {"databaseId": 2, "path": "src/b.py", "line": 20, "body": "resolved already", "diffHunk": "@@", "author": {"login": "Copilot", "__typename": "Bot"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 3, "path": "src/c.py", "line": 30, "body": "human nit", "diffHunk": "@@", "author": {"login": "octocat", "__typename": "User"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": []}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 5, "path": "src/e.py", "line": null, "body": "ghost author", "diffHunk": "@@", "author": null}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 6, "path": "src/f.py", "line": 60, "body": "real bot login", "diffHunk": "@@", "author": {"login": "copilot-pull-request-reviewer", "__typename": "Bot"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 7, "path": "src/g.py", "line": 70, "body": "human handle contains copilot", "diffHunk": "@@", "author": {"login": "copilot-fan", "__typename": "User"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": null, "path": "src/h.py", "line": 80, "body": "pending review comment", "diffHunk": "@@", "author": {"login": "octocat", "__typename": "User"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 9, "path": "src/i.py", "line": 90, "body": "thread root", "diffHunk": "@@", "author": {"login": "octocat", "__typename": "User"}},
    {"databaseId": 10, "path": "src/i.py", "line": 90, "body": "a reply", "diffHunk": "@@", "author": {"login": "Copilot", "__typename": "Bot"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 11, "path": "src/j.py", "line": 110, "body": "greptile nit", "diffHunk": "@@", "author": {"login": "greptile-apps", "__typename": "Bot"}}
  ]}}
]'

result=$(echo "$nodes" | transform)

# ── Test: only unresolved threads with a non-null root comment id survive ───

count=$(echo "$result" | jq 'length')
assert "keeps 7 of 10 threads (drops resolved, empty-comment, null databaseId)" test "$count" -eq 7

ids=$(echo "$result" | jq -c '[.[].id] | sort')
assert "keeps comment IDs 1, 3, 5, 6, 7, 9, 11" test "$ids" = "[1,3,5,6,7,9,11]"

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

# ── Test: bot authorship detected ──────────────────────────────────────────
# is_bot keys off the "Bot" author type, OR'd with the Copilot login check so
# Copilot counts even when its __typename is absent.

# Copilot with no __typename: the login fallback must still flag it. The "Copilot"
# fixture (capital C) also pins case-insensitivity in COPILOT_LOGIN_JQ.
is_bot_1=$(echo "$result" | jq -r '.[] | select(.id == 1) | .is_bot')
assert "Copilot comment flagged is_bot=true via login fallback" test "$is_bot_1" = "true"

# Production Copilot login typed as "Bot".
is_bot_6=$(echo "$result" | jq -r '.[] | select(.id == 6) | .is_bot')
assert "production Copilot login flagged is_bot=true" test "$is_bot_6" = "true"

# A non-Copilot bot (Greptile) typed as "Bot" must also be flagged so its thread is
# replied to and resolved like any other bot's.
is_bot_11=$(echo "$result" | jq -r '.[] | select(.id == 11) | .is_bot')
assert "non-Copilot bot (Greptile) flagged is_bot=true" test "$is_bot_11" = "true"

# A human handle that merely contains "copilot" is typed "User", so it is NOT a bot;
# their thread must stay open like any other human reviewer's.
is_bot_7=$(echo "$result" | jq -r '.[] | select(.id == 7) | .is_bot')
assert "human handle containing 'copilot' is not a bot" test "$is_bot_7" = "false"

# ── Test: human authorship detected ────────────────────────────────────────

is_bot_3=$(echo "$result" | jq -r '.[] | select(.id == 3) | .is_bot')
assert "human comment flagged is_bot=false" test "$is_bot_3" = "false"
author_3=$(echo "$result" | jq -r '.[] | select(.id == 3) | .author')
assert "human author login preserved" test "$author_3" = "octocat"

# ── Test: null author falls back to unknown, not a bot ─────────────────────

author_5=$(echo "$result" | jq -r '.[] | select(.id == 5) | .author')
assert "null author becomes 'unknown'" test "$author_5" = "unknown"
is_bot_5=$(echo "$result" | jq -r '.[] | select(.id == 5) | .is_bot')
assert "null author is not a bot" test "$is_bot_5" = "false"

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
