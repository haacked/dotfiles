#!/bin/bash
# Shared test helpers for bin/lib/ test scripts.
#
# Usage: source "$SCRIPT_DIR/test-helpers.sh"
#
# Provides assert/assert_not functions, socket/agent fixtures for SSH-agent
# tests, a bounded runner for the script under test, and a print_results
# finalizer. Each test file should call print_results at the end.

_helpers_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/bounded.sh
source "$_helpers_dir/bounded.sh"

passes=0
failures=0

# Runs $BIN under $FAKE_HOME with any arguments given, echoing its stdout and
# returning its exit status, or 124 if it had to be killed.
#
# Bounded because these suites drive SSH agents and signing paths, the code
# most able to block forever, and they run by hand with no CI timeout behind
# them. Unbounded, a regression in the very hang-avoidance being tested wedges
# the run instead of failing it, and the assertion written to catch it is never
# reached. Callers that need to distinguish a hang from an expected failure
# should assert the status is not 124.
# shellcheck disable=SC2120  # most callers pass no arguments
run_bin() {
    run_bounded 10 env HOME="$FAKE_HOME" "$BIN" "$@"
}

# Binds a dead AF_UNIX socket at $1: passes -S liveness checks but refuses
# connections, for simulating an agent that's gone by connect time.
mksock() {
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
}

# Binds a listening AF_UNIX socket at $1 that accepts connections and then
# never answers, simulating a forwarded agent whose SSH transport stalled: the
# path passes -S, connect() succeeds, and ssh-add waits forever for a reply
# that never comes. This is the shape mksock cannot produce, since a bound but
# unlistened socket refuses the connection outright. Echoes the holder's PID so
# the caller can kill it during cleanup.
mkblackhole_sock() {
    local pid waited=0
    python3 -c '
import socket, sys
s = socket.socket(socket.AF_UNIX)
s.bind(sys.argv[1])
s.listen(16)
held = []
while True:
    conn, _ = s.accept()
    held.append(conn)
' "$1" >/dev/null &
    pid=$!
    while [[ ! -S "$1" ]] && (( waited < 100 )); do
        # Without this, a holder that died before binding leaves the caller with
        # a path that never becomes a socket, and every assertion written to
        # catch a stalled agent instead passes against a missing one.
        kill -0 "$pid" 2>/dev/null || {
            echo "mkblackhole_sock: holder died before binding $1" >&2
            return 1
        }
        sleep 0.05
        waited=$((waited + 1))
    done
    [[ -S "$1" ]] || { echo "mkblackhole_sock: no socket at $1" >&2; return 1; }
    printf '%s\n' "$pid"
}

# The Secretive agent socket path under a fake HOME ($1), mirroring the path
# hardcoded in bin/ssh-agent-sync.
secretive_sock() {
    printf '%s/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh\n' "$1"
}

# Starts a real ssh-agent listening on $1 without eval'ing its output (that
# would export SSH_AUTH_SOCK into the caller's own environment). Echoes its
# PID so the caller can kill it during cleanup.
start_agent() {
    local sock="$1" out
    out=$(ssh-agent -a "$sock")
    printf '%s\n' "$out" | sed -n 's/^SSH_AGENT_PID=\([0-9]*\);.*/\1/p'
}

assert() {
    local description="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -eq 0 ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        failures=$((failures + 1))
    fi
}

assert_not() {
    local description="$1"
    shift
    local rc=0
    "$@" || rc=$?
    if [[ "$rc" -ne 0 ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        failures=$((failures + 1))
    fi
}

print_results() {
    echo ""
    echo "Results: $passes passed, $failures failed"
    [[ "$failures" -eq 0 ]]
}
