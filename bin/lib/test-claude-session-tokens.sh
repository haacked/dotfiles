#!/bin/bash
# Tests for bin/claude-session-tokens, which reads token usage from the
# transcript of the Claude Code session that runs it.
#
# Usage: test-claude-session-tokens.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../claude-session-tokens"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

FAKE_HOME="$TESTTMP/home"
WORKDIR="$TESTTMP/work"
mkdir -p "$WORKDIR"
# The script encodes os.getcwd(), which resolves the /var symlink on macOS.
WORKDIR=$(cd "$WORKDIR" && pwd -P)
PROJECT="$FAKE_HOME/.claude/projects/$(printf '%s' "$WORKDIR" | tr '/.' '--')"
SESSION_TRANSCRIPT="$PROJECT/this-session.jsonl"
SUBAGENT_TRANSCRIPT="$PROJECT/this-session/subagents/agent-a1.jsonl"
OTHER_TRANSCRIPT="$PROJECT/other-session.jsonl"
mkdir -p "$(dirname "$SUBAGENT_TRANSCRIPT")"

transcript() { # file output-tokens...
    local file="$1"
    shift
    : >"$file"
    for n in "$@"; do
        printf '{"type":"assistant","message":{"usage":{"output_tokens":%s}}}\n' "$n" >>"$file"
    done
}

transcript "$SESSION_TRANSCRIPT" 1
transcript "$SUBAGENT_TRANSCRIPT" 1 2 3
transcript "$OTHER_TRANSCRIPT" 1 2 3 4 5

newest() { # file: gives this file the newest modification time of the three
    touch -t 202601010000 "$SESSION_TRANSCRIPT" "$SUBAGENT_TRANSCRIPT" "$OTHER_TRANSCRIPT"
    touch -t 202601010100 "$1"
}

in_session() { # session-id args...
    local session="$1"
    shift
    (cd "$WORKDIR" && export CLAUDE_CODE_SESSION_ID="$session" && run_bin "$@")
}

without_session() { # args...
    (cd "$WORKDIR" && unset CLAUDE_CODE_SESSION_ID && run_bin "$@")
}

# ── Test: a forked subagent reads its own transcript ─────────────────────

newest "$SUBAGENT_TRANSCRIPT"
touch -t 202601010200 "$OTHER_TRANSCRIPT"
assert "a session's newest subagent transcript wins over another session's newer transcript" \
    test "$(in_session this-session --line-count)" = 3

# ── Test: the session's own transcript when no subagent is newer ─────────

newest "$SESSION_TRANSCRIPT"
touch -t 202601010200 "$OTHER_TRANSCRIPT"
assert "the session's main transcript is used when it is the session's newest" \
    test "$(in_session this-session --line-count)" = 1

# ── Test: --sum-from sums the selected transcript ────────────────────────

newest "$SUBAGENT_TRANSCRIPT"
assert "--sum-from sums the subagent transcript from the given line" \
    test "$(in_session this-session --sum-from 2 | jq -r .output_tokens)" = 5

# ── Test: without a session ID the project's newest transcript is used ───

newest "$SUBAGENT_TRANSCRIPT"
assert "without a session ID a subagent transcript can be the newest" \
    test "$(without_session --line-count)" = 3

newest "$OTHER_TRANSCRIPT"
assert "without a session ID any session's transcript can be the newest" \
    test "$(without_session --line-count)" = 5

# ── Test: an unknown session finds nothing ───────────────────────────────

finds_transcript() { # session-id
    in_session "$1" --line-count >/dev/null 2>&1
}

assert_not "a session with no transcript in this project fails" finds_transcript no-such-session

print_results
