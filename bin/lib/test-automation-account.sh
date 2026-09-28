#!/bin/bash
# Tests for use_automation_account in automation-account.sh.
#
# Usage: test-automation-account.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="$SCRIPT_DIR/automation-account.sh"

# shellcheck source=bin/lib/logging.sh
source "$SCRIPT_DIR/logging.sh"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

# An inherited value would change what the assertions below see.
unset CLAUDE_CONFIG_DIR

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

SIGNED_IN_DIR="$TESTTMP/automation"
SIGNED_OUT_DIR="$TESTTMP/signed-out-automation"
MISSING_DIR="$TESTTMP/missing-automation"
OUT="$TESTTMP/out"
default_home="$TESTTMP/home"
mkdir -p "$SIGNED_IN_DIR" "$SIGNED_OUT_DIR" "$default_home/.claude-automation"

# Claude Code records the signed-in account under oauthAccount in the config
# dir's .claude.json. A directory that was never signed in has no oauthAccount.
signed_in_config='{"oauthAccount": {"emailAddress": "bot@example.com", "organizationName": "Example Org"}}'
printf '%s\n' "$signed_in_config" >"$SIGNED_IN_DIR/.claude.json"
printf '%s\n' "$signed_in_config" >"$default_home/.claude-automation/.claude.json"
printf '%s\n' '{"theme": "dark"}' >"$SIGNED_OUT_DIR/.claude.json"

# shellcheck source=bin/lib/automation-account.sh
source "$LIB"

output_has_line_with() { # level-tag fixed-string
    grep -F "$1" "$OUT" | grep -Fq "$2"
}

# ── Test: a signed-in directory is exported as CLAUDE_CONFIG_DIR ──────────

unset CLAUDE_CONFIG_DIR
AUTOMATION_CLAUDE_CONFIG_DIR="$SIGNED_IN_DIR"
status=0
use_automation_account >"$OUT" 2>&1 || status=$?
child_sees=$(bash -c 'printf %s "${CLAUDE_CONFIG_DIR-}"')

assert "Signed-in dir returns 0" test "$status" -eq 0
assert "Signed-in dir is visible to a child process" test "$child_sees" = "$SIGNED_IN_DIR"
assert "Signed-in dir logs an INFO line naming it" output_has_line_with "[INFO]" "$SIGNED_IN_DIR"
assert "Signed-in dir logs the account email" output_has_line_with "[INFO]" "bot@example.com"
assert "Signed-in dir logs the account's organization" output_has_line_with "[INFO]" "Example Org"

# ── Test: a directory that is not signed in leaves CLAUDE_CONFIG_DIR unset ─

unset CLAUDE_CONFIG_DIR
AUTOMATION_CLAUDE_CONFIG_DIR="$SIGNED_OUT_DIR"
status=0
use_automation_account >"$OUT" 2>&1 || status=$?

assert "Signed-out dir returns 0 so the job continues" test "$status" -eq 0
assert "Signed-out dir leaves CLAUDE_CONFIG_DIR unset" test -z "${CLAUDE_CONFIG_DIR+set}"
assert "Signed-out dir logs a WARN line naming the path" output_has_line_with "[WARN]" "$SIGNED_OUT_DIR"

# ── Test: a missing directory leaves an unset CLAUDE_CONFIG_DIR unset ──────

unset CLAUDE_CONFIG_DIR
AUTOMATION_CLAUDE_CONFIG_DIR="$MISSING_DIR"
status=0
use_automation_account >"$OUT" 2>&1 || status=$?

assert "Missing dir returns 0 so the job continues" test "$status" -eq 0
assert "Missing dir leaves CLAUDE_CONFIG_DIR unset" test -z "${CLAUDE_CONFIG_DIR+set}"
assert "Missing dir logs a WARN line naming the path" output_has_line_with "[WARN]" "$MISSING_DIR"

# ── Test: a missing directory leaves a preset CLAUDE_CONFIG_DIR alone ──────

export CLAUDE_CONFIG_DIR="$TESTTMP/preset-config"
AUTOMATION_CLAUDE_CONFIG_DIR="$MISSING_DIR"
status=0
use_automation_account >"$OUT" 2>&1 || status=$?

assert "Missing dir with a preset value returns 0" test "$status" -eq 0
assert "Missing dir keeps the preset CLAUDE_CONFIG_DIR" test "${CLAUDE_CONFIG_DIR-}" = "$TESTTMP/preset-config"
unset CLAUDE_CONFIG_DIR

# ── Test: a signed-in ~/.claude-automation is selected by default ──────────

default_selected=$(
    unset CLAUDE_CONFIG_DIR
    # An inherited value must not move the directory the scheduled jobs use.
    AUTOMATION_CLAUDE_CONFIG_DIR="$MISSING_DIR"
    HOME="$default_home"
    # shellcheck source=bin/lib/automation-account.sh
    source "$LIB"
    use_automation_account >/dev/null 2>&1 || true
    bash -c 'printf %s "${CLAUDE_CONFIG_DIR-}"'
)

assert "Default dir is exported when it is signed in" test "$default_selected" = "$default_home/.claude-automation"

# ── Results ────────────────────────────────────────────────────────────────

print_results
