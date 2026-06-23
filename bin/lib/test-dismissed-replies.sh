#!/bin/bash
# Tests for process_dismissed_comments routing in copilot-review-loop.sh.
#
# The routing is safety-critical: Copilot dismissed comments get their drafted
# reply POSTED and queued for resolution, while human dismissed comments are
# only GATHERED to files for the user to post manually — never posted here.
#
# Usage: test-dismissed-replies.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# Source the loop script for its functions. The source guard keeps main() from
# running; the top-level arg parsing is a no-op with no positional parameters.
# shellcheck source=bin/copilot-review-loop.sh
source "$SCRIPT_DIR/../copilot-review-loop.sh"

# Stub gh so nothing hits the network. Record each call's args verbatim so we can
# assert exactly what would have been posted. Defined after sourcing so it wins.
GH_CALLS_FILE="$(mktemp)"
gh() { printf '%s\n' "$*" >> "$GH_CALLS_FILE"; }

# ── Fixture globals process_dismissed_comments reads ────────────────────────

REPO="acme/widgets"
OWNER="acme"
REPO_NAME="widgets"
PR_NUMBER=123

COPILOT_REPLY="This is valid in Python 3.10+, our minimum version."
HUMAN_REPLY="Good question — it's intentional; see the comment I added."

new_comments=$(cat <<JSON
[
  {"id": 1, "path": "src/a.py", "line": 10, "body": "copilot says fix this", "author": "Copilot", "is_copilot": true},
  {"id": 2, "path": "src/b.py", "line": 20, "body": "human asks about this", "author": "alice", "is_copilot": false}
]
JSON
)

summary=$(jq -nc \
  --arg cr "$COPILOT_REPLY" \
  --arg hr "$HUMAN_REPLY" \
  '{
    fixed: [],
    dismissed: [
      {id: 1, confidence: "high", reason: "false positive", path: "src/a.py", line: 10, reply: $cr},
      {id: 2, confidence: "high", reason: "intentional", path: "src/b.py", line: 20, reply: $hr}
    ],
    needs_human: [],
    errors: []
  }')

# ── Scenario: one Copilot + one human dismissed comment ─────────────────────

STATE_DIR="$(mktemp -d)"
human_replies_file="$(mktemp)"
STATE='{"dismissed_comments":[],"rounds":[]}'

process_dismissed_comments "$summary" "$new_comments" 1

# gh is called exactly once — only for the Copilot comment.
gh_call_count=$(wc -l < "$GH_CALLS_FILE" | tr -d ' ')
assert "gh called exactly once" test "$gh_call_count" -eq 1

# That one call targets the Copilot comment (id 1) and carries the Copilot reply.
assert "gh call targets Copilot comment 1" \
  grep -q 'comments/1/replies' "$GH_CALLS_FILE"
assert "gh call carries the Copilot reply text" \
  grep -qF "$COPILOT_REPLY" "$GH_CALLS_FILE"

# The human comment (id 2) is NEVER posted.
assert_not "human comment 2 is never posted" \
  grep -q 'comments/2/replies' "$GH_CALLS_FILE"
assert_not "human reply text is never posted" \
  grep -qF "$HUMAN_REPLY" "$GH_CALLS_FILE"

# Only the Copilot thread is queued for resolution.
resolve_str="${RESOLVE_ARGS[*]}"
assert "only Copilot thread queued for resolution" \
  test "$resolve_str" = "--comment-id 1"

# The human reply is gathered to a persistent file with the exact body.
human_file="${STATE_DIR}/acme-widgets-123-reply-2.txt"
assert "human reply file exists" test -f "$human_file"
assert "human reply file holds the drafted reply" \
  test "$(cat "$human_file")" = "$HUMAN_REPLY"

# No reply file is written for the Copilot comment (it was posted, not gathered).
assert_not "no gathered file for Copilot comment" \
  test -f "${STATE_DIR}/acme-widgets-123-reply-1.txt"

# The human-replies index has exactly one entry, for comment 2.
index_count=$(wc -l < "$human_replies_file" | tr -d ' ')
assert "human-replies index has one entry" test "$index_count" -eq 1
indexed_id=$(jq -r '.id' "$human_replies_file")
assert "indexed entry is comment 2" test "$indexed_id" -eq 2
indexed_author=$(jq -r '.author' "$human_replies_file")
assert "indexed entry records author" test "$indexed_author" = "alice"
indexed_reply=$(jq -r '.reply' "$human_replies_file")
assert "indexed entry records the reply" test "$indexed_reply" = "$HUMAN_REPLY"

# Both comments are recorded in state so they're filtered in future rounds.
state_dismissed=$(echo "$STATE" | jq '.dismissed_comments | length')
assert "both dismissed comments recorded in state" test "$state_dismissed" -eq 2

# ── Scenario: empty dismissed array is a safe no-op ─────────────────────────

: > "$GH_CALLS_FILE"
human_replies_file="$(mktemp)"
empty_summary='{"fixed":[],"dismissed":[],"needs_human":[],"errors":[]}'

process_dismissed_comments "$empty_summary" "$new_comments" 2

gh_call_count=$(wc -l < "$GH_CALLS_FILE" | tr -d ' ')
assert "no gh calls when nothing dismissed" test "$gh_call_count" -eq 0
assert "no resolution args when nothing dismissed" test "${#RESOLVE_ARGS[@]}" -eq 0
empty_index_count=$(wc -l < "$human_replies_file" | tr -d ' ')
assert "no gathered replies when nothing dismissed" test "$empty_index_count" -eq 0

# ── Results ─────────────────────────────────────────────────────────────────

print_results
