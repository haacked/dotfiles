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
# A mix of resolved/unresolved threads, Copilot/human/null authors, and a
# thread with no root comment.

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
  ]}}
]'

result=$(echo "$nodes" | transform)

# ── Test: only unresolved threads with a root comment survive ──────────────

count=$(echo "$result" | jq 'length')
assert "keeps 3 of 5 threads (drops resolved + empty-comment)" test "$count" -eq 3

ids=$(echo "$result" | jq -c '[.[].id] | sort')
assert "keeps comment IDs 1, 3, 5" test "$ids" = "[1,3,5]"

# ── Test: Copilot authorship detected ──────────────────────────────────────

is_copilot_1=$(echo "$result" | jq -r '.[] | select(.id == 1) | .is_copilot')
assert "Copilot comment flagged is_copilot=true" test "$is_copilot_1" = "true"

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
line_5=$(echo "$result" | jq -r '.[] | select(.id == 5) | .line')
assert "null line preserved as null" test "$line_5" = "null"

# ── Test: empty input array yields empty output ────────────────────────────

empty=$(echo '[]' | transform | jq 'length')
assert "empty input returns empty output" test "$empty" -eq 0

# ── Results ───────────────────────────────────────────────────────────────

print_results
