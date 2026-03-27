#!/bin/bash
# Tests for start_heartbeat/stop_heartbeat in logging.sh.
#
# Usage: test-heartbeat.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/logging.sh
source "$SCRIPT_DIR/logging.sh"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# ── Test: start_heartbeat sets a valid PID ─────────────────────────────────

start_heartbeat 60 "test"
assert "PID is set after start" test -n "$_HEARTBEAT_PID"
assert "PID is a running process" kill -0 "$_HEARTBEAT_PID"
stop_heartbeat

# ── Test: stop_heartbeat clears PID and kills process ──────────────────────

start_heartbeat 60 "test"
saved_pid="$_HEARTBEAT_PID"
stop_heartbeat
assert "PID is cleared after stop" test -z "$_HEARTBEAT_PID"
assert_not "Process is no longer running" kill -0 "$saved_pid" 2>/dev/null

# ── Test: stop_heartbeat is safe when nothing is running ───────────────────

_HEARTBEAT_PID=""
stop_heartbeat
assert "No error calling stop when already stopped" test -z "$_HEARTBEAT_PID"

# ── Test: double start kills the first process ─────────────────────────────

start_heartbeat 60 "first"
first_pid="$_HEARTBEAT_PID"
start_heartbeat 60 "second"
assert "PID changed on second start" test "$_HEARTBEAT_PID" != "$first_pid"
assert_not "First process was killed" kill -0 "$first_pid" 2>/dev/null
assert "Second process is running" kill -0 "$_HEARTBEAT_PID"
stop_heartbeat

# ── Test: heartbeat printf uses stderr ─────────────────────────────────────
# Verified by inspecting the printf format string which ends with >&2.
# A runtime test would require fd gymnastics that complicate the test
# more than they're worth for a single line of code.

# ── Results ────────────────────────────────────────────────────────────────

print_results
