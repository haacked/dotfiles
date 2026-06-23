#!/bin/bash
# Tests for process_dismissed_comments routing in copilot-review-loop.sh.
#
# The routing is safety-critical: Copilot dismissed comments get their drafted
# reply POSTED and queued for resolution, while human dismissed comments are
# only GATHERED to files for the user to post manually, never posted here.
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

# All temp artifacts live under one dir so a single trap cleans them up.
TESTTMP="$(mktemp -d)"
trap 'rm -rf "$TESTTMP"' EXIT

# Stub gh so nothing hits the network. Record each call's args verbatim so we can
# assert exactly what would have been posted. Defined after sourcing so it wins.
GH_CALLS_FILE="$TESTTMP/gh-calls"
: > "$GH_CALLS_FILE"
gh() { printf '%s\n' "$*" >> "$GH_CALLS_FILE"; }

# ── Fixture globals process_dismissed_comments reads ────────────────────────

REPO="acme/widgets"
OWNER="acme"
REPO_NAME="widgets"
PR_NUMBER=123

COPILOT_REPLY="This is valid in Python 3.10+, our minimum version."
HUMAN_REPLY="Good question; it's intentional, see the comment I added."
HUMAN_REPLY_2="Already covered by the validation above."

new_comments=$(cat <<JSON
[
  {"id": 1, "path": "src/a.py", "line": 10, "body": "copilot says fix this", "author": "Copilot", "is_copilot": true},
  {"id": 2, "path": "src/b.py", "line": 20, "body": "alice asks about this", "author": "alice", "is_copilot": false},
  {"id": 3, "path": "src/c.py", "line": 30, "body": "bob asks about this", "author": "bob", "is_copilot": false}
]
JSON
)

summary=$(jq -nc \
  --arg cr "$COPILOT_REPLY" \
  --arg hr "$HUMAN_REPLY" \
  --arg hr2 "$HUMAN_REPLY_2" \
  '{
    fixed: [],
    dismissed: [
      {id: 1, confidence: "high", reason: "false positive", path: "src/a.py", line: 10, reply: $cr},
      {id: 2, confidence: "high", reason: "intentional", path: "src/b.py", line: 20, reply: $hr},
      {id: 3, confidence: "high", reason: "already handled", path: "src/c.py", line: 30, reply: $hr2}
    ],
    needs_human: [],
    errors: []
  }')

# ── Scenario: one Copilot + two human dismissed comments ────────────────────

STATE_DIR="$TESTTMP/state"
mkdir -p "$STATE_DIR"
human_replies_file="$TESTTMP/human-replies"
: > "$human_replies_file"
STATE='{"dismissed_comments":[],"rounds":[]}'

process_dismissed_comments "$summary" "$new_comments" 1

# gh is called exactly once, only for the Copilot comment.
gh_call_count=$(wc -l < "$GH_CALLS_FILE" | tr -d ' ')
assert "gh called exactly once" test "$gh_call_count" -eq 1

# That one call targets the Copilot comment (id 1) and carries the Copilot reply.
assert "gh call targets Copilot comment 1" \
  grep -q 'comments/1/replies' "$GH_CALLS_FILE"
assert "gh call carries the Copilot reply text" \
  grep -qF "$COPILOT_REPLY" "$GH_CALLS_FILE"

# Neither human comment (id 2, id 3) is ever posted.
assert_not "human comment 2 is never posted" \
  grep -q 'comments/2/replies' "$GH_CALLS_FILE"
assert_not "human comment 3 is never posted" \
  grep -q 'comments/3/replies' "$GH_CALLS_FILE"
assert_not "human reply text is never posted" \
  grep -qF "$HUMAN_REPLY" "$GH_CALLS_FILE"

# Only the Copilot thread is queued for resolution.
resolve_str="${RESOLVE_ARGS[*]}"
assert "only Copilot thread queued for resolution" \
  test "$resolve_str" = "--comment-id 1"

# Each human reply is gathered to its own persistent file with the exact body.
assert "human reply file for comment 2 exists" \
  test -f "${STATE_DIR}/acme-widgets-123-reply-2.txt"
assert "human reply file 2 holds the drafted reply" \
  test "$(cat "${STATE_DIR}/acme-widgets-123-reply-2.txt")" = "$HUMAN_REPLY"
assert "human reply file for comment 3 exists" \
  test -f "${STATE_DIR}/acme-widgets-123-reply-3.txt"
assert "human reply file 3 holds the drafted reply" \
  test "$(cat "${STATE_DIR}/acme-widgets-123-reply-3.txt")" = "$HUMAN_REPLY_2"

# No reply file is written for the Copilot comment (it was posted, not gathered).
assert_not "no gathered file for Copilot comment" \
  test -f "${STATE_DIR}/acme-widgets-123-reply-1.txt"

# The human-replies index accumulates one line per human comment (not overwritten).
index_count=$(wc -l < "$human_replies_file" | tr -d ' ')
assert "human-replies index has two entries" test "$index_count" -eq 2
indexed_ids=$(jq -r '.id' "$human_replies_file" | sort | tr '\n' ' ')
assert "indexed entries are comments 2 and 3" test "$indexed_ids" = "2 3 "
entry2_author=$(jq -r 'select(.id == 2) | .author' "$human_replies_file")
assert "index records the author for comment 2" test "$entry2_author" = "alice"
entry2_reply=$(jq -r 'select(.id == 2) | .reply' "$human_replies_file")
assert "index records the reply for comment 2" test "$entry2_reply" = "$HUMAN_REPLY"

# All three dismissed comments are recorded in state so they're filtered next round.
state_dismissed=$(echo "$STATE" | jq '.dismissed_comments | length')
assert "all dismissed comments recorded in state" test "$state_dismissed" -eq 3

# ── Scenario: a Copilot comment with an empty reply is left unresolved ──────
# Resolution requires a posted reply. An empty draft means nothing to say, so we
# skip the post AND leave the thread open rather than closing it silently.

: > "$GH_CALLS_FILE"
human_replies_file="$TESTTMP/human-replies-empty-reply"
: > "$human_replies_file"
STATE='{"dismissed_comments":[],"rounds":[]}'
empty_reply_summary=$(jq -nc '{
  fixed: [], needs_human: [], errors: [],
  dismissed: [{id: 1, confidence: "high", reason: "fp", path: "src/a.py", line: 10, reply: ""}]
}')

process_dismissed_comments "$empty_reply_summary" "$new_comments" 2

assert_not "no gh post when the Copilot reply is empty" \
  grep -q 'comments/1/replies' "$GH_CALLS_FILE"
assert "Copilot thread NOT queued when reply is empty" \
  test "${#RESOLVE_ARGS[@]}" -eq 0

# ── Scenario: a failed gh post leaves the Copilot thread unresolved ─────────
# Resolving a thread whose reply never posted would swallow the rationale, so a
# failed post must not queue the thread for resolution.

: > "$GH_CALLS_FILE"
human_replies_file="$TESTTMP/human-replies-post-fail"
: > "$human_replies_file"
STATE='{"dismissed_comments":[],"rounds":[]}'
gh() { printf '%s\n' "$*" >> "$GH_CALLS_FILE"; return 1; }   # simulate a failed post
copilot_only_summary=$(jq -nc --arg cr "$COPILOT_REPLY" '{
  fixed: [], needs_human: [], errors: [],
  dismissed: [{id: 1, confidence: "high", reason: "fp", path: "src/a.py", line: 10, reply: $cr}]
}')

process_dismissed_comments "$copilot_only_summary" "$new_comments" 3

assert "post was attempted even though it failed" \
  grep -q 'comments/1/replies' "$GH_CALLS_FILE"
assert "Copilot thread NOT queued after a failed post" \
  test "${#RESOLVE_ARGS[@]}" -eq 0

gh() { printf '%s\n' "$*" >> "$GH_CALLS_FILE"; }   # restore the success stub

# ── Scenario: empty dismissed array is a safe no-op ─────────────────────────

: > "$GH_CALLS_FILE"
human_replies_file="$TESTTMP/human-replies-empty"
: > "$human_replies_file"
empty_summary='{"fixed":[],"dismissed":[],"needs_human":[],"errors":[]}'

process_dismissed_comments "$empty_summary" "$new_comments" 4

gh_call_count=$(wc -l < "$GH_CALLS_FILE" | tr -d ' ')
assert "no gh calls when nothing dismissed" test "$gh_call_count" -eq 0
assert "no resolution args when nothing dismissed" test "${#RESOLVE_ARGS[@]}" -eq 0
empty_index_count=$(wc -l < "$human_replies_file" | tr -d ' ')
assert "no gathered replies when nothing dismissed" test "$empty_index_count" -eq 0

# ── Results ─────────────────────────────────────────────────────────────────

print_results
