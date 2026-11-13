#!/bin/bash
# Tests for the skill and agent loaders in claude-worker.sh, for how
# claude_worker_init and claude_worker_run use them, and for the resume command
# that names the run's Claude account.
#
# Usage: test-claude-worker.sh

# shellcheck disable=SC2016 # jq filters and expected skill text contain a literal $ or backtick.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=bin/lib/logging.sh
source "$SCRIPT_DIR/logging.sh"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/claude-worker.sh
source "$SCRIPT_DIR/claude-worker.sh"

# Inherited values would change the arguments claude_worker_run passes to claude.
unset CLAUDE_CONFIG_DIR WORKER_AGENTS WORKER_ALLOWED_TOOLS WORKER_MODEL

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

# The sourced value points at the real ~/.claude-automation. A test that wants
# the automation account sets its own directory.
# shellcheck disable=SC2034 # use_automation_account reads it.
AUTOMATION_CLAUDE_CONFIG_DIR="$TESTTMP/missing-automation"

FIXTURE="$TESTTMP/repo"
AGENTS="$FIXTURE/ai/agents"
SKILL_BODY="$TESTTMP/skill-body.md"
STUB_BIN="$TESTTMP/stubs"
CLAUDE_ARGS_FILE="$TESTTMP/claude-args"
CLAUDE_ENV_FILE="$TESTTMP/claude-env"
RUN_LOG="$TESTTMP/run.log"
mkdir -p "$AGENTS" "$FIXTURE/ai/skills/fixture-skill" "$STUB_BIN"

# ── Fixtures ──────────────────────────────────────────────────────────────

cat >"$SKILL_BODY" <<'EOF'
# Fixture Skill

Run `gh issue list` first.
Then record $(date +%s) and keep ${HOME} literal.

---

## After the rule

name: not-frontmatter
EOF
{
    printf '%s\n' '---' 'name: fixture-skill' 'description: A fixture skill: used by tests' \
        'disable-model-invocation: true' '---' ''
    cat "$SKILL_BODY"
} >"$FIXTURE/ai/skills/fixture-skill/SKILL.md"

printf '%s\n' '---' 'name: alpha' 'description: Alpha agent' 'model: sonnet' 'color: blue' '---' \
    '' '' 'You are the alpha agent.' '' 'Follow the steps.' '   ' '' >"$AGENTS/alpha.md"
printf '%s\n' '---' 'name: beta' 'description: Beta agent' 'model: haiku' '---' \
    'You are the beta agent.' >"$AGENTS/beta.md"
printf '%s\n' '---' 'name: inheritor' 'description: Inherits the model' 'model: inherit' '---' \
    'Body.' >"$AGENTS/inheritor.md"
printf '%s\n' '---' 'name: modelless' 'description: Has no model' '---' \
    'Body.' >"$AGENTS/modelless.md"
printf '%s\n' '---' 'name: "quoted-agent"' 'description: "Triage: flags and \"cohorts\""' '---' \
    'Body.' >"$AGENTS/quoted.md"
printf '%s\n' '---' 'name: colon' 'description: Analyzes issues: flags, cohorts' '---' \
    'Body.' >"$AGENTS/colon.md"
printf '%s\n' '---' 'name: ruled' 'description: Has a rule in its body' 'model: haiku' '---' \
    'Intro.' '' '---' '' 'model: opus' >"$AGENTS/ruled.md"
printf '%s\n' '# No Frontmatter' '' 'Body.' >"$AGENTS/no-frontmatter.md"

write_passthrough_shims "$STUB_BIN"
# The claude stub records its arguments and CLAUDE_CONFIG_DIR, and prints
# CLAUDE_STUB_STDOUT. The arguments are NUL-delimited because the prompt and the
# --agents JSON can span several lines.
cat >"$STUB_BIN/claude" <<STUB
#!/bin/bash
printf '%s\0' "\$@" >"$CLAUDE_ARGS_FILE"
printf '%s' "\${CLAUDE_CONFIG_DIR-unset}" >"$CLAUDE_ENV_FILE"
printf '%s' "\${CLAUDE_STUB_STDOUT-}"
STUB
# claude_worker_init calls uuidgen, which a CI runner may lack.
cat >"$STUB_BIN/uuidgen" <<'STUB'
#!/bin/bash
echo 00000000-0000-4000-8000-000000000000
STUB
chmod +x "$STUB_BIN/claude" "$STUB_BIN/uuidgen"

# ── Helpers ───────────────────────────────────────────────────────────────

json_check() { # json filter [jq-args...]
    local json="$1" filter="$2"
    shift 2
    printf '%s' "$json" | jq -e "$@" "$filter" >/dev/null 2>&1
}

starts_with() { # text prefix
    [[ "$1" == "$2"* ]]
}

strip_leading_blank_lines() {
    printf '%s\n' "$1" | sed '/./,$!d'
}

# The negative checks below fail when there is nothing to inspect: no recorded
# claude call, or no function under test. An error about missing code therefore
# cannot pass as the expected behavior.

worker_agents_json_rejects() { # agent-name...
    declare -F worker_agents_json >/dev/null && ! worker_agents_json "$@" >/dev/null 2>&1
}

load_claude_args() {
    CLAUDE_ARGS=()
    [[ -f "$CLAUDE_ARGS_FILE" ]] || return 0
    local arg
    while IFS= read -r -d '' arg; do
        CLAUDE_ARGS+=("$arg")
    done <"$CLAUDE_ARGS_FILE"
}

claude_has_arg() { # arg
    local arg
    for arg in ${CLAUDE_ARGS[@]+"${CLAUDE_ARGS[@]}"}; do
        [[ "$arg" == "$1" ]] && return 0
    done
    return 1
}

claude_lacks_arg() { # arg
    [[ ${#CLAUDE_ARGS[@]} -gt 0 ]] && ! claude_has_arg "$1"
}

claude_arg_after() { # flag
    local i
    for ((i = 0; i + 1 < ${#CLAUDE_ARGS[@]}; i++)); do
        if [[ "${CLAUDE_ARGS[i]}" == "$1" ]]; then
            printf '%s' "${CLAUDE_ARGS[i + 1]}"
            return 0
        fi
    done
    return 1
}

claude_arg_is() { # flag expected-value
    local value
    value=$(claude_arg_after "$1") || return 1
    [[ "$value" == "$2" ]]
}

# Runs claude_worker_run in a subshell because the function ends with exit.
# Bash ignores set -e inside a subshell that is part of an || or && list.
# Production runs claude_worker_run with set -e in force, so the subshell runs
# in the background and the status comes from wait. Call run_worker on its own
# line for the same reason. It stores the status in RUN_STATUS.
run_worker() {
    rm -f "$CLAUDE_ARGS_FILE"
    RUN_STATUS=0
    (
        PATH="$STUB_BIN:$PATH"
        claude_worker_run "test-worker" "Run the fixture prompt."
    ) >"$RUN_LOG" 2>&1 &
    wait "$!" || RUN_STATUS=$?
    load_claude_args
}

# ── Test: skill_instructions prints a skill body without its frontmatter ──

WORKING_DIR="$FIXTURE"
skill_out=$(skill_instructions fixture-skill) || true

assert "skill_instructions prints exactly the body after the frontmatter" \
    test "$(strip_leading_blank_lines "$skill_out")" = "$(cat "$SKILL_BODY")"

# ── Test: skill_instructions reads the real triage-issues skill ───────────

WORKING_DIR="$REPO_ROOT"
real_skill_out=$(skill_instructions triage-issues) || true

assert "triage-issues output starts at its title" \
    starts_with "$(strip_leading_blank_lines "$real_skill_out")" "# Triage GitHub Issues"

# ── Test: worker_agents_json maps agent files to --agents JSON ────────────

WORKING_DIR="$FIXTURE"
agents_json=$(worker_agents_json alpha beta inheritor modelless quoted colon ruled) || true

assert "worker_agents_json keys each agent by its name" \
    json_check "$agents_json" 'keys == ["alpha", "beta", "colon", "inheritor", "modelless", "quoted-agent", "ruled"]'
assert "worker_agents_json keeps description and model, trims the body, and drops other keys" \
    json_check "$agents_json" '.alpha == {description: "Alpha agent", model: "sonnet", prompt: $p}' \
    --arg p $'You are the alpha agent.\n\nFollow the steps.'
assert "worker_agents_json passes model: inherit through" json_check "$agents_json" '.inheritor.model == "inherit"'
assert "worker_agents_json leaves out a model the file does not set" \
    json_check "$agents_json" '.modelless | has("model") | not'
assert "worker_agents_json decodes a quoted value, escaped quotes included" \
    json_check "$agents_json" '.["quoted-agent"].description == $d' --arg d 'Triage: flags and "cohorts"'
assert "worker_agents_json keeps everything after the first colon of an unquoted value" \
    json_check "$agents_json" '.colon.description == "Analyzes issues: flags, cohorts"'
assert "worker_agents_json ends the frontmatter at the first closing ---" \
    json_check "$agents_json" '.ruled == {description: "Has a rule in its body", model: "haiku", prompt: $p}' \
    --arg p $'Intro.\n\n---\n\nmodel: opus'
# The missing agent comes first. An implementation that reports only the last file's status cannot pass.
assert "worker_agents_json fails when an agent file is missing" worker_agents_json_rejects missing-agent alpha
assert "worker_agents_json fails on a file with no frontmatter" worker_agents_json_rejects no-frontmatter

# ── Test: worker_agents_json reads the real triage-feature-flags agent ────

WORKING_DIR="$REPO_ROOT"
real_agents_json=$(worker_agents_json triage-feature-flags) || true

assert "triage-feature-flags is keyed by its name" json_check "$real_agents_json" 'keys == ["triage-feature-flags"]'
assert "triage-feature-flags prompt starts at the body" \
    json_check "$real_agents_json" '.["triage-feature-flags"].prompt | startswith("You are a triage specialist")'

# ── Test: claude_worker_init puts the repo's bin first on PATH ────────────

# A fixed base PATH keeps a repo bin entry from the caller's shell out of the result.
init_base_path="$STUB_BIN:/usr/bin:/bin"
init_path=$(
    HOME="$TESTTMP/home"
    PATH="$init_base_path"
    claude_worker_init "test-worker" >/dev/null
    bash -c 'printf %s "$PATH"'
) || true

assert "claude_worker_init puts the repo's bin before the inherited PATH" \
    test "$init_path" = "$REPO_ROOT/bin:$init_base_path"

# ── Test: claude_worker_init stops when timeout is not on PATH ────────────

# STUB_BIN, Ubuntu's /usr/bin and Homebrew's bin each hold a timeout. PATH
# therefore leaves out every real directory.
no_timeout_log="$TESTTMP/no-timeout.log"
no_timeout_status=0
(
    HOME="$TESTTMP/home"
    # shellcheck disable=SC2123
    PATH="$TESTTMP/no-such-dir"
    claude_worker_init "no-timeout-worker"
) >"$no_timeout_log" 2>&1 || no_timeout_status=$?

assert "claude_worker_init fails when timeout is missing" test "$no_timeout_status" -ne 0
assert "claude_worker_init tells the user to install coreutils when timeout is missing" \
    grep -qF "brew install coreutils" "$no_timeout_log"

# ── Test: the DM footer's resume command names the run's account ──────────

# The space makes the footer quote the directory.
SIGNED_IN_AUTOMATION="$TESTTMP/signed in automation"
mkdir -p "$SIGNED_IN_AUTOMATION"
printf '%s\n' '{"oauthAccount": {"emailAddress": "bot@example.com", "organizationName": "Example Org"}}' \
    >"$SIGNED_IN_AUTOMATION/.claude.json"
FIXED_SESSION="00000000-0000-4000-8000-000000000000"

# Runs claude_worker_init and then prints the DM step, in the order a worker
# builds its prompt. jq stays on PATH, because without it the automation
# directory reads as signed out.
init_then_dm_step() { # state-name automation-dir
    (
        unset CLAUDE_CONFIG_DIR
        HOME="$TESTTMP/home"
        PATH="$STUB_BIN:$PATH"
        AUTOMATION_CLAUDE_CONFIG_DIR="$2"
        claude_worker_init "$1" >/dev/null 2>&1
        slack_dm_instructions 2 "the digest" "To dig in:"
    )
}

dm_step_has_line() { # dm-step expected-line
    printf '%s\n' "$1" | sed 's/^ *//' | grep -qxF "$2"
}

automation_dm_step=$(init_then_dm_step automation-worker "$SIGNED_IN_AUTOMATION") || true
assert "an automation run's DM footer resumes under the automation account" \
    dm_step_has_line "$automation_dm_step" "CLAUDE_CONFIG_DIR='$SIGNED_IN_AUTOMATION' claude --resume $FIXED_SESSION"
assert "claude_worker_init records the automation account's config directory" \
    test "$(cat "$TESTTMP/home/.local/state/automation-worker/last-session-config-dir" 2>/dev/null)" = "$SIGNED_IN_AUTOMATION"

default_dm_step=$(init_then_dm_step default-worker "$TESTTMP/missing-automation") || true
assert "a default-login run's DM footer resumes with a plain claude --resume" \
    dm_step_has_line "$default_dm_step" "claude --resume $FIXED_SESSION"
assert "claude_worker_init records an empty config directory for the default login" \
    test "$(cat "$TESTTMP/home/.local/state/default-worker/last-session-config-dir" 2>/dev/null || echo missing)" = ""

# ── claude_worker_run setup ───────────────────────────────────────────────

WORKING_DIR="$FIXTURE"
SESSION_ID="00000000-0000-4000-8000-000000000000"
MAX_BUDGET_USD=1
RUN_TIMEOUT_SECONDS=30
RUN_KILL_AFTER_SECONDS=5
WORKER_STATE_NAME="test-worker"

# ── Test: a run with no knobs uses bypassPermissions and nothing else ─────

run_worker

assert "a run without knobs exits 0" test "$RUN_STATUS" -eq 0
assert "a run without an allowlist uses bypassPermissions" claude_arg_is --permission-mode bypassPermissions
assert "a run without an allowlist passes no --allowedTools" claude_lacks_arg --allowedTools
assert "an unset WORKER_AGENTS adds no --agents" claude_lacks_arg --agents
assert "an unset WORKER_MODEL adds no --model" claude_lacks_arg --model

# ── Test: WORKER_AGENTS passes every listed agent through --agents ────────

WORKER_AGENTS=(alpha beta)
run_worker
unset WORKER_AGENTS

assert "a run with agents exits 0" test "$RUN_STATUS" -eq 0
assert "the --agents value holds every listed agent" \
    json_check "$(claude_arg_after --agents)" 'keys == ["alpha", "beta"]'

# ── Test: an empty WORKER_AGENTS adds no --agents ─────────────────────────

WORKER_AGENTS=()
run_worker
unset WORKER_AGENTS

assert "a run with an empty WORKER_AGENTS exits 0" test "$RUN_STATUS" -eq 0
assert "an empty WORKER_AGENTS adds no --agents" claude_lacks_arg --agents

# ── Test: WORKER_MODEL passes --model ─────────────────────────────────────

WORKER_MODEL="sonnet"
run_worker
unset WORKER_MODEL

assert "a run with a model exits 0" test "$RUN_STATUS" -eq 0
assert "WORKER_MODEL passes its value through --model" claude_arg_is --model sonnet

# ── Test: an allowlist run keeps its permission args and adds --agents ────

WORKER_ALLOWED_TOOLS=("Skill" "Bash(gh issue view:*)")
WORKER_AGENTS=(alpha)
run_worker
unset WORKER_AGENTS WORKER_ALLOWED_TOOLS

assert "an allowlist run exits 0" test "$RUN_STATUS" -eq 0
assert "an allowlist run uses permission mode default" claude_arg_is --permission-mode default
assert "an allowlist run loads no settings files" claude_arg_is --setting-sources ""
assert "an allowlist run passes the first rule after --allowedTools" claude_arg_is --allowedTools "Skill"
assert "an allowlist run passes every rule" claude_has_arg "Bash(gh issue view:*)"
assert "an allowlist run with agents passes them through --agents" \
    json_check "$(claude_arg_after --agents)" 'keys == ["alpha"]'

# ── Test: a missing agent file stops the run before claude starts ─────────

WORKER_AGENTS=(missing-agent)
run_worker
unset WORKER_AGENTS

assert "a missing agent file fails the run" test "$RUN_STATUS" -ne 0
assert "a missing agent file keeps claude from starting" test ! -f "$CLAUDE_ARGS_FILE"

# ── Test: an undelivered DM logs the resume command for the run's account ─

export CLAUDE_STUB_STDOUT="$WORKER_DM_FAILED_SENTINEL"
export CLAUDE_CONFIG_DIR="$SIGNED_IN_AUTOMATION"
run_worker
assert "an automation run with an undelivered DM exits 3" test "$RUN_STATUS" -eq 3
assert "claude_worker_run keeps the exported CLAUDE_CONFIG_DIR for claude" \
    test "$(cat "$CLAUDE_ENV_FILE")" = "$SIGNED_IN_AUTOMATION"
assert "an automation run's undelivered-DM error resumes under the automation account" \
    grep -qF "Resume: CLAUDE_CONFIG_DIR='$SIGNED_IN_AUTOMATION' claude --resume $SESSION_ID" "$RUN_LOG"

unset CLAUDE_CONFIG_DIR
run_worker
unset CLAUDE_STUB_STDOUT
assert "a default-login run with an undelivered DM exits 3" test "$RUN_STATUS" -eq 3
assert "a default-login run's undelivered-DM error resumes with a plain claude --resume" \
    grep -qF "Resume: claude --resume $SESSION_ID" "$RUN_LOG"

# ── Results ───────────────────────────────────────────────────────────────

print_results
