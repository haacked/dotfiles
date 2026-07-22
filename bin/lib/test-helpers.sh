#!/bin/bash
# Shared test helpers for bin/lib/ test scripts.
#
# Usage: source "$SCRIPT_DIR/test-helpers.sh"
#
# Provides assert/assert_not functions, socket/agent fixtures for SSH-agent
# tests, and a print_results finalizer. Each test file should call
# print_results at the end.

passes=0
failures=0

# Binds a dead AF_UNIX socket at $1: passes -S liveness checks but refuses
# connections, for simulating an agent that's gone by connect time.
mksock() {
    python3 -c 'import socket, sys; socket.socket(socket.AF_UNIX).bind(sys.argv[1])' "$1"
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
