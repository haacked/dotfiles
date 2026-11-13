#!/bin/bash
# Tests for the `status` and `resume` commands in launchd-service.sh, which
# resume a job's last session under the Claude account that ran it.
#
# Usage: test-launchd-service.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

FAKE_HOME="$TESTTMP/home"
REPO="$TESTTMP/repo"
STATE_DIR="$FAKE_HOME/.local/state/test-service"
STUB_BIN="$TESTTMP/stubs"
SERVICE="$TESTTMP/test-service.sh"
CLAUDE_CALL="$TESTTMP/claude-call"
OUT="$TESTTMP/out"
SESSION="00000000-0000-4000-8000-000000000000"
# The space makes the printed command quote the directory.
AUTOMATION_DIR="$TESTTMP/automation dir"
mkdir -p "$REPO" "$STATE_DIR" "$STUB_BIN"
# mktemp makes TESTTMP under /var on macOS. The claude stub records pwd -P,
# which resolves /var to /private/var.
REPO=$(cd "$REPO" && pwd -P)

cat >"$SERVICE" <<SERVICE
#!/usr/bin/env bash
set -euo pipefail
source "$SCRIPT_DIR/logging.sh"
source "$SCRIPT_DIR/launchd-service.sh"
SERVICE_NAME="test-service"
WORKER="/usr/bin/true"
REPO_ROOT="$REPO"
launchd_service_main "\$@"
SERVICE

# The claude stub records CLAUDE_CONFIG_DIR, its arguments, and its working
# directory.
cat >"$STUB_BIN/claude" <<STUB
#!/bin/bash
printf '%s|%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$*" "\$(pwd -P)" >"$CLAUDE_CALL"
STUB
printf '#!/bin/sh\n' >"$STUB_BIN/launchctl"
chmod +x "$SERVICE" "$STUB_BIN/claude" "$STUB_BIN/launchctl"

# Runs the service command with CLAUDE_CONFIG_DIR set to the given value, which
# stands for the account of the shell the user runs it from.
run_service() { # inherited-config-dir command
    rm -f "$CLAUDE_CALL"
    RUN_STATUS=0
    CLAUDE_CONFIG_DIR="$1" HOME="$FAKE_HOME" PATH="$STUB_BIN:$PATH" "$SERVICE" "$2" >"$OUT" 2>&1 ||
        RUN_STATUS=$?
}

claude_call() {
    cat "$CLAUDE_CALL" 2>/dev/null || true
}

printf '%s\n' "$SESSION" >"$STATE_DIR/last-session-id"

# ── Test: a session from the automation account resumes under it ──────────

printf '%s\n' "$AUTOMATION_DIR" >"$STATE_DIR/last-session-config-dir"

run_service "$FAKE_HOME/.claude-personal" status
assert "status for an automation session exits 0" test "$RUN_STATUS" -eq 0
assert "status prints the resume command under the automation account" \
    grep -qxF "  Resume with: cd $REPO && CLAUDE_CONFIG_DIR='$AUTOMATION_DIR' claude --resume $SESSION" "$OUT"

run_service "$FAKE_HOME/.claude-personal" resume
assert "resume for an automation session exits 0" test "$RUN_STATUS" -eq 0
assert "resume runs claude under the automation account from the repo root" \
    test "$(claude_call)" = "$AUTOMATION_DIR|--resume $SESSION|$REPO"

# ── Test: a session from the default login resumes under it ───────────────

printf '\n' >"$STATE_DIR/last-session-config-dir"

run_service "$FAKE_HOME/.claude-personal" status
assert "status for a default-login session prints a plain claude --resume" \
    grep -qxF "  Resume with: cd $REPO && claude --resume $SESSION" "$OUT"

run_service "$FAKE_HOME/.claude-personal" resume
assert "resume for a default-login session drops an inherited CLAUDE_CONFIG_DIR" \
    test "$(claude_call)" = "unset|--resume $SESSION|$REPO"

# ── Test: a session recorded before accounts were recorded ────────────────

rm "$STATE_DIR/last-session-config-dir"

run_service "$FAKE_HOME/.claude-personal" status
assert "status without a recorded account prints a plain claude --resume" \
    grep -qxF "  Resume with: cd $REPO && claude --resume $SESSION" "$OUT"

run_service "$FAKE_HOME/.claude-personal" resume
assert "resume without a recorded account uses the default login" \
    test "$(claude_call)" = "unset|--resume $SESSION|$REPO"

print_results
