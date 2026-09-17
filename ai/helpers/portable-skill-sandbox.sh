#!/usr/bin/env bash
# The sandbox scaffolding each portable skill's scripts/tests/test-portable-skill.sh
# runs its assertions in.
#
# A portable skill is uploaded on its own to a cloud sandbox holding no clone of this
# repo, so every script it runs has to resolve inside its own folder. Each skill's test
# proves that by copying the folder elsewhere, pointing DOTFILES_DIR at a directory
# that does not exist, and running entry points under env -i from an unrelated working
# directory. A test never runs in that sandbox, so it may source this file even though
# the skill's own scripts may not.
#
# Usage: source portable-skill-sandbox.sh, then:
#   sandbox=$(make_portable_sandbox <skill-dir>)
#   assert_run <description> <expected_status> <jq_filter> <expected> <cmd...>
#   assert_line_count <description> <file> <expected>
#   print_results
#
# Declare a `local -a ASSERT_ENV=(NAME=value ...)` in a wrapper to add environment for
# one call. Writing the array as a command prefix on assert_run instead assigns its
# literal text as a scalar, so the wrapper has to declare it.

passes=0
failures=0

# Each assert_run writes its own stdout and stderr files and leaves their paths in
# ASSERT_STDOUT and ASSERT_STDERR. A follow-up check that reads one captures the path
# into its own variable, so inserting another assertion between the two cannot point
# the check at a different command's output.
_assert_runs=0

make_portable_sandbox() { # skill-dir
    local sandbox
    sandbox=$(mktemp -d)
    mkdir -p "$sandbox/bin" "$sandbox/home" "$sandbox/unrelated"
    cp -R "$1" "$sandbox/skill"
    printf '%s\n' "$sandbox"
}

assert_run() { # description expected_status jq_filter expected cmd...
    local description="$1" expected_status="$2" jq_filter="$3" expected="$4"
    shift 4
    local status=0 actual
    _assert_runs=$((_assert_runs + 1))
    ASSERT_STDOUT="$sandbox/stdout.$_assert_runs"
    ASSERT_STDERR="$sandbox/stderr.$_assert_runs"
    env -i HOME="$sandbox/home" DOTFILES_DIR="$sandbox/missing" PATH="$sandbox/bin:$PATH" \
        ${ASSERT_ENV[@]+"${ASSERT_ENV[@]}"} \
        "$@" >"$ASSERT_STDOUT" 2>"$ASSERT_STDERR" || status=$?
    actual=$(<"$ASSERT_STDOUT")
    if [ -n "$jq_filter" ]; then
        actual=$(jq -cr "$jq_filter" "$ASSERT_STDOUT") || actual='invalid JSON'
    fi
    if [ "$status" = "$expected_status" ] && [ "$actual" = "$expected" ]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $description"
        echo "  expected exit $expected_status and '$expected'; got exit $status and '$actual'"
        cat "$ASSERT_STDERR"
        failures=$((failures + 1))
    fi
}

assert_line_count() { # description file expected
    local actual
    actual=$(wc -l <"$2" | tr -d ' ')
    if [ "$actual" = "$3" ]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $1 (got $actual, expected $3)"
        failures=$((failures + 1))
    fi
}

print_results() {
    echo "$passes passed, $failures failed"
    [ "$failures" -eq 0 ]
}
