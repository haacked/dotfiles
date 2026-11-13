#!/bin/bash
# Tests for automation-account.sh: use_automation_account, the session record,
# and the resume command.
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

# ── Test: automation_account_name reports the signed-in account ───────────

AUTOMATION_CLAUDE_CONFIG_DIR="$SIGNED_IN_DIR"
assert "automation_account_name prints the signed-in account" \
    test "$(automation_account_name)" = "bot@example.com (Example Org)"
AUTOMATION_CLAUDE_CONFIG_DIR="$SIGNED_OUT_DIR"
assert "automation_account_name prints nothing when signed out" \
    test -z "$(automation_account_name)"
AUTOMATION_CLAUDE_CONFIG_DIR="$MISSING_DIR"
status=0
name=$(automation_account_name) || status=$?
assert "automation_account_name prints nothing and succeeds when the directory is missing" \
    test "$status" -eq 0 -a -z "$name"

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

# ── Test: claude_resume_command names the account's config directory ──────

STUB_BIN="$TESTTMP/stubs"
CLAUDE_CALL="$TESTTMP/claude-call"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/claude" <<STUB
#!/bin/sh
printf '%s|%s\n' "\${CLAUDE_CONFIG_DIR-unset}" "\$*" >"$CLAUDE_CALL"
STUB
chmod +x "$STUB_BIN/claude"

# Prints the command under POSIX sh, because the sh installer sources the file.
resume_command_in_sh() { # config-dir session-id
    sh -c '. "$1"; claude_resume_command "$2" "$3"' sh "$LIB" "$1" "$2"
}

# Runs a printed command in sh with the claude stub first on PATH and prints
# the CLAUDE_CONFIG_DIR and arguments the stub saw.
run_printed_command() { # command
    rm -f "$CLAUDE_CALL"
    (unset CLAUDE_CONFIG_DIR && PATH="$STUB_BIN:$PATH" sh -c 'eval "$1"' sh "$1")
    cat "$CLAUDE_CALL" 2>/dev/null || true
}

session="00000000-0000-4000-8000-000000000000"

assert "The default login's resume command sets no config directory" \
    test "$(resume_command_in_sh "" "$session")" = "claude --resume $session"
assert "The automation account's resume command names its config directory" \
    test "$(resume_command_in_sh "/Users/someone/.claude-automation" "$session")" = \
    "CLAUDE_CONFIG_DIR=/Users/someone/.claude-automation claude --resume $session"
assert "The default login's resume command runs claude with no config directory" \
    test "$(run_printed_command "$(resume_command_in_sh "" "$session")")" = "unset|--resume $session"

tricky_dir="$TESTTMP/it's a \$HOME dir:~x"
tricky_command=$(resume_command_in_sh "$tricky_dir" "$session")
assert "A resume command passes a directory with spaces, quotes, and \$ through the shell intact" \
    test "$(run_printed_command "$tricky_command")" = "$tricky_dir|--resume $session"
assert "bash prints the same resume command as sh" \
    test "$(claude_resume_command "$tricky_dir" "$session")" = "$tricky_command"

# ── Test: record_last_session writes the session and its account ──────────

state_dir="$TESTTMP/state"
mkdir -p "$state_dir"

assert "last_session_config_dir prints nothing before any run records one" \
    test -z "$(last_session_config_dir "$state_dir")"

export CLAUDE_CONFIG_DIR="$tricky_dir"
record_last_session "$state_dir" "$session"
assert "record_last_session writes the session ID" test "$(cat "$state_dir/last-session-id")" = "$session"
assert "record_last_session records the automation account's config directory" \
    test "$(last_session_config_dir "$state_dir")" = "$tricky_dir"

unset CLAUDE_CONFIG_DIR
record_last_session "$state_dir" "11111111-0000-4000-8000-000000000000"
assert "record_last_session replaces the session ID" \
    test "$(cat "$state_dir/last-session-id")" = "11111111-0000-4000-8000-000000000000"
assert "record_last_session clears an earlier account for a default-login run" \
    test -z "$(last_session_config_dir "$state_dir")"

# ── Results ────────────────────────────────────────────────────────────────

print_results
