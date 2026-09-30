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

# Runs script $2 in a new bash process with a deadline of $1 seconds. It stores
# the status in child_status. The script gets logging.sh's path as $1. On a
# timeout, run_bounded kills the bash process but not the heartbeat subshell
# that it forked. The subshell has the same command line, which carries
# child_tag. pkill therefore finds it.
child_tag="test-heartbeat-$$"
run_heartbeat_child() {
  child_status=0
  run_bounded "$1" "$BASH" -c "$2" "$child_tag" "$SCRIPT_DIR/logging.sh" || child_status=$?
  if (( child_status == 124 )); then pkill -KILL -f "$child_tag" || true; fi
}

# ── Test: stop_heartbeat returns right after start_heartbeat ───────────────
# Under bash 3.2, stop_heartbeat called right after start_heartbeat hung once
# in every few hundred cycles. The test runs 1000 cycles so that nearly every
# run catches it. The hang occurred only when start_heartbeat ran in a main
# shell, never in a subshell. run_bounded runs its command in a subshell.
# cycle_heartbeat therefore runs in a new bash process.

cycle_heartbeat() {
  local i
  for ((i = 0; i < 1000; i++)); do
    start_heartbeat 1 "cycle"
    stop_heartbeat
  done
}
export -f cycle_heartbeat

# shellcheck disable=SC2016
run_heartbeat_child 20 'source "$1"; cycle_heartbeat'
assert "stop_heartbeat returns right after start_heartbeat (status $child_status)" test "$child_status" -eq 0

# ── Test: stop_heartbeat stops a heartbeat that ignores TERM ───────────────
# The heartbeat subshell inherits a caller's trap '' TERM.

# shellcheck disable=SC2016
run_heartbeat_child 5 'trap "" TERM; source "$1"; start_heartbeat 60 "ignored"; stop_heartbeat'
assert "stop_heartbeat returns when the caller ignores TERM (status $child_status)" test "$child_status" -eq 0

# ── Results ────────────────────────────────────────────────────────────────

print_results
