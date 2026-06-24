# claude-worker.sh - Shared plumbing for launchd workers that drive a headless
# claude session and DM the result.
#
# A worker sources this file (after logging.sh), sets its budget knobs, calls
# `claude_worker_init <state-name>`, builds its PROMPT (typically embedding
# $SESSION_ID and a DM step from `slack_dm_instructions`), and finishes with
# `claude_worker_run "<heartbeat label>" "$PROMPT"`.
#
# Knobs (set before claude_worker_run; all have no defaults here so each
# worker's env-overridable defaults stay next to its config):
#   MAX_BUDGET_USD          --max-budget-usd for the claude run
#   RUN_TIMEOUT_SECONDS     wall-clock timeout for the claude run
#   RUN_KILL_AFTER_SECONDS  SIGKILL delay if claude ignores SIGTERM
#   WORKER_ALLOWED_TOOLS    optional array of permission rules. When set, the
#                           run uses --permission-mode default with exactly
#                           these rules allowed and loads no settings files,
#                           so the broad interactive allowlist in
#                           ~/.claude/settings.json does not apply; any tool
#                           call outside the list is denied (headless runs
#                           have nobody to approve a prompt). Required for
#                           workers that ingest untrusted content (public
#                           GitHub issue/PR text): without it the run uses
#                           bypassPermissions, where injected instructions
#                           can reach Bash and every MCP tool unconfirmed.

# Slack DM recipient for digests and drafts: Phil Haack (phil.h@posthog.com).
# Hardcoded so scheduled runs don't burn a slack_search_users round trip on a
# fixed input.
SLACK_DM_USER_ID="${SLACK_DM_USER_ID:-U086UNZDP37}"

# claude_worker_init <state-name>
# Sets WORKING_DIR (the repo root, auto-detected so the worker runs correctly
# whether invoked from ~/.dotfiles or from a worktree), cds into it, creates
# ~/.local/state/<state-name>, and pre-generates SESSION_ID (recorded in
# last-session-id) so the prompt can embed it in a DM footer and the service
# script's `resume` command can find it.
claude_worker_init() {
  WORKER_STATE_NAME="$1"
  WORKING_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
  STATE_DIR="${HOME}/.local/state/${WORKER_STATE_NAME}"
  mkdir -p "$STATE_DIR"
  LAST_SESSION_FILE="${STATE_DIR}/last-session-id"
  SESSION_ID=$(uuidgen | tr '[:upper:]' '[:lower:]')
  echo "$SESSION_ID" > "$LAST_SESSION_FILE"
  cd "$WORKING_DIR"
}

# slack_dm_instructions <step-number> <content-description> <footer-intro>
# Emits the standard prompt step for DMing the run's output: send via
# mcp__claude_ai_Slack__slack_send_message to $SLACK_DM_USER_ID, body =
# content + blank line + fenced footer with the resume command. Use the
# claude.ai Slack connector, not the plugin Slack MCP: the connector is the
# transport available in BOTH worker modes. Jobs with an allowlist run with
# `--setting-sources ""` (see claude_worker_run), which doesn't load the plugin
# MCP, so mcp__plugin_slack_slack is absent there; the connector still loads.
slack_dm_instructions() {
  local step="$1" content="$2" footer_intro="$3"
  cat <<EOF
${step}. Send ${content} as a Slack DM using
   mcp__claude_ai_Slack__slack_send_message to Slack user ID
   ${SLACK_DM_USER_ID} (the channel argument is the user ID; Slack opens the
   DM channel automatically). The DM body has three parts, in this order:
   a. ${content}
   b. A blank line
   c. A footer block in a fenced code block, verbatim:

      ${footer_intro}
        cd ${WORKING_DIR}
        claude --resume ${SESSION_ID}
EOF
}

# claude_worker_run <heartbeat-label> <prompt>
# Runs claude headless with the standard guards and logs the outcome.
# caffeinate -i blocks idle sleep so the timeout measures real wall-clock
# time; timeout --kill-after fires SIGKILL if claude ignores SIGTERM.
claude_worker_run() {
  local heartbeat_label="$1" prompt="$2"

  local -a permission_args
  if [[ -n "${WORKER_ALLOWED_TOOLS[*]+set}" ]]; then
    log_info "Tool allowlist: ${WORKER_ALLOWED_TOOLS[*]}"
    permission_args=(
      --permission-mode default
      --setting-sources ""
      --allowedTools "${WORKER_ALLOWED_TOOLS[@]}"
    )
  else
    permission_args=(--permission-mode bypassPermissions)
  fi

  log_info "Invoking claude --print"
  start_heartbeat 60 "$heartbeat_label"
  set +e
  caffeinate -i timeout --kill-after="$RUN_KILL_AFTER_SECONDS" \
    "$RUN_TIMEOUT_SECONDS" \
    claude --print \
      --session-id "$SESSION_ID" \
      "${permission_args[@]}" \
      --max-budget-usd "$MAX_BUDGET_USD" \
      --output-format text \
      "$prompt"
  local exit_code=$?
  set -e
  stop_heartbeat

  if [[ $exit_code -eq 0 ]]; then
    log_success "${WORKER_STATE_NAME} finished (session $SESSION_ID)"
  elif [[ $exit_code -eq 124 ]]; then
    log_error "${WORKER_STATE_NAME} timed out after ${RUN_TIMEOUT_SECONDS}s"
  else
    log_error "${WORKER_STATE_NAME} failed with exit code $exit_code"
  fi

  exit "$exit_code"
}
