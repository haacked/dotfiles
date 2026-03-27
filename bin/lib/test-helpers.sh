#!/bin/bash
# Shared test helpers for bin/lib/ test scripts.
#
# Usage: source "$SCRIPT_DIR/test-helpers.sh"
#
# Provides assert/assert_not functions and a print_results finalizer.
# Each test file should call print_results at the end.

passes=0
failures=0

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
