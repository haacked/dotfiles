#!/bin/bash
# Tests for the prompt and the claude arguments that bin/pr-followups-run builds.
#
# Usage: test-pr-followups-run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../pr-followups-run"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
SCAN_SCRIPT="$REPO_ROOT/ai/skills/pr-followups/scripts/pr-followups.py"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

STUB_BIN="$TESTTMP/stubs"
PROMPT_FILE="$TESTTMP/prompt"
ARGS_FILE="$TESTTMP/args"
RUN_LOG="$TESTTMP/run.log"
SESSION="00000000-0000-4000-8000-000000000000"
mkdir -p "$STUB_BIN"

write_passthrough_shims "$STUB_BIN"
# The claude stub saves its arguments one per line and its last argument, the
# prompt, and runs nothing.
cat >"$STUB_BIN/claude" <<STUB
#!/bin/bash
printf '%s\n' "\$@" >"$ARGS_FILE"
printf '%s' "\${@: -1}" >"$PROMPT_FILE"
STUB
cat >"$STUB_BIN/uuidgen" <<STUB
#!/bin/bash
echo $SESSION
STUB
chmod +x "$STUB_BIN/claude" "$STUB_BIN/uuidgen"

run_worker() { # home
    rm -f "$PROMPT_FILE" "$ARGS_FILE"
    RUN_STATUS=0
    (
        unset CLAUDE_CONFIG_DIR
        HOME="$1" PATH="$STUB_BIN:$PATH" "$RUNNER"
    ) >"$RUN_LOG" 2>&1 || RUN_STATUS=$?
}

prompt_has_line() { # expected-line
    sed 's/^ *//' "$PROMPT_FILE" 2>/dev/null | grep -qxF "$1"
}

prompt_contains() { # text
    grep -qF -- "$1" "$PROMPT_FILE" 2>/dev/null
}

# Prints the values that follow --allowedTools, up to the next flag.
allowed_tools() {
    awk '/^--allowedTools$/ { on = 1; next } on && /^--/ { on = 0 } on' "$ARGS_FILE"
}

arg_follows() { # flag value
    awk -v flag="$1" -v want="$2" 'prev == flag && $0 == want { found = 1 } { prev = $0 } END { exit !found }' "$ARGS_FILE"
}

# ── Test: a run on the default login builds the Slack-mode prompt ─────────

home="$TESTTMP/default-home"
mkdir -p "$home"

run_worker "$home"

assert "The run exits 0" test "$RUN_STATUS" -eq 0
assert "The DM footer resumes the session" prompt_has_line "claude --resume $SESSION"
assert "The prompt DMs the fixed user ID" prompt_contains "U086UNZDP37"
assert "The prompt runs Slack mode" prompt_contains "--format slack"
assert "The prompt runs the scan by its absolute path" prompt_has_line "$SCAN_SCRIPT scan"
assert "The prompt embeds the skill's instructions" prompt_contains "# PR follow-ups"
assert "The prompt skips the DM when nothing is left to send" \
    prompt_contains "If no findings are left, or the scan failed, skip steps 2 and 3."
assert "The prompt records only after a successful send" \
    prompt_contains "Only after the send in step 2 succeeded, run the record command"
assert "The prompt quotes each recorded key" \
    prompt_has_line "$SCAN_SCRIPT record --sent '<key>' --sent '<key>'"

# ── Test: the run allows exactly four tools and pins its model ─────────────

expected_tools="ToolSearch
Bash($SCAN_SCRIPT scan:*)
Bash($SCAN_SCRIPT record:*)
mcp__claude_ai_Slack__slack_send_message"

assert "The run allows exactly the four tools" test "$(allowed_tools)" = "$expected_tools"
assert "The run pins the sonnet model" arg_follows "--model" "sonnet"

print_results
