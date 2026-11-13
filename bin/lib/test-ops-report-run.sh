#!/bin/bash
# Tests for the resume command that bin/ops-report-run puts in its DM footer and
# for the session record it leaves for `ops-report-service.sh resume`.
#
# Usage: test-ops-report-run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../ops-report-run"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

STUB_BIN="$TESTTMP/stubs"
PROMPT_FILE="$TESTTMP/prompt"
RUN_LOG="$TESTTMP/run.log"
SESSION="00000000-0000-4000-8000-000000000000"
mkdir -p "$STUB_BIN"

write_passthrough_shims "$STUB_BIN"
# The claude stub saves its last argument, the prompt, and runs nothing.
cat >"$STUB_BIN/claude" <<STUB
#!/bin/bash
printf '%s' "\${@: -1}" >"$PROMPT_FILE"
STUB
cat >"$STUB_BIN/uuidgen" <<STUB
#!/bin/bash
echo $SESSION
STUB
chmod +x "$STUB_BIN/claude" "$STUB_BIN/uuidgen"

# Runs the daily report under a fake HOME. jq stays on PATH, because without it
# the automation directory reads as signed out.
run_report() { # home
    rm -f "$PROMPT_FILE"
    RUN_STATUS=0
    (
        unset CLAUDE_CONFIG_DIR
        HOME="$1" PATH="$STUB_BIN:$PATH" "$RUNNER" day
    ) >"$RUN_LOG" 2>&1 || RUN_STATUS=$?
}

prompt_has_line() { # expected-line
    sed 's/^ *//' "$PROMPT_FILE" 2>/dev/null | grep -qxF "$1"
}

recorded_config_dir() { # home
    cat "$1/.local/state/ops-report-daily/last-session-config-dir" 2>/dev/null || echo missing
}

# ── Test: a run under the automation account names it in the footer ───────

automation_home="$TESTTMP/automation-home"
mkdir -p "$automation_home/.claude-automation"
printf '%s\n' '{"oauthAccount": {"emailAddress": "bot@example.com", "organizationName": "Example Org"}}' \
    >"$automation_home/.claude-automation/.claude.json"

run_report "$automation_home"

assert "An automation run exits 0" test "$RUN_STATUS" -eq 0
assert "An automation run's DM footer resumes under the automation account" \
    prompt_has_line "CLAUDE_CONFIG_DIR=$automation_home/.claude-automation claude --resume $SESSION"
assert "An automation run records the automation account's config directory" \
    test "$(recorded_config_dir "$automation_home")" = "$automation_home/.claude-automation"

# ── Test: a run on the default login uses a plain resume command ──────────

default_home="$TESTTMP/default-home"
mkdir -p "$default_home"

run_report "$default_home"

assert "A default-login run exits 0" test "$RUN_STATUS" -eq 0
assert "A default-login run's DM footer uses a plain claude --resume" \
    prompt_has_line "claude --resume $SESSION"
assert "A default-login run records an empty config directory" \
    test "$(recorded_config_dir "$default_home")" = ""

print_results
