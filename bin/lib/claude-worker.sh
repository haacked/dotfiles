# claude-worker.sh - Shared plumbing for launchd workers that drive a headless
# claude session and DM the result.
#
# A worker sources this file (after logging.sh), sets its budget knobs, calls
# `claude_worker_init <state-name>`, builds its PROMPT (typically embedding
# $SESSION_ID and a DM step from `slack_dm_instructions`), and finishes with
# `claude_worker_run "<heartbeat label>" "$PROMPT"`.
#
# A headless `claude --print` run has no further turns, so a worker that can't
# deliver its Slack DM cannot "wait and retry later" — it just ends, and the
# wrapper would see exit 0 and report success even though nothing was sent.
# `slack_dm_instructions` tells the worker to print WORKER_DM_FAILED_SENTINEL
# (plus the undelivered body) when it gives up, and `claude_worker_run` greps
# the captured stdout for that marker and exits non-zero so the failure is
# visible in the log instead of masked as success.
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

# Marker a worker prints (per slack_dm_instructions) when it exhausts Slack send
# retries. claude_worker_run greps the run's stdout for it to detect a delivery
# failure that would otherwise look like success (the run still exits 0). Kept
# distinctive so it never collides with real output.
WORKER_DM_FAILED_SENTINEL="<<<WORKER_DM_DELIVERY_FAILED>>>"

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

   If the send fails, retry it inline a few times (up to 4 attempts total).
   Do NOT start a background timer or wait for a completion notification to
   fire a later retry: this is a non-interactive --print run with no further
   turns, so nothing will ever wake you and the run would stall until it is
   killed. Run the retries back to back, then stop.

   If every attempt still fails (e.g. the Slack write path is down), give up
   on delivery and, as the very LAST thing you output, print this marker on a
   line by itself, exactly:

     ${WORKER_DM_FAILED_SENTINEL}

   then print the full DM body you could not send, so it is captured in the
   run log for recovery. Print the marker ONLY when the DM was not delivered;
   never print it after a successful send.
EOF
}

# slack_channel_instructions <step-number> <content-description> <channel-id>
# Emits the standard prompt step for posting the run's output directly to a
# Slack channel: send via mcp__claude_ai_Slack__slack_send_message to
# <channel-id>. Unlike slack_dm_instructions, the body carries no
# resume-session footer — that's internal housekeeping that doesn't belong in
# a message the whole channel sees. Reuses WORKER_DM_FAILED_SENTINEL: the
# marker means "delivery failed," regardless of transport.
slack_channel_instructions() {
  local step="$1" content="$2" channel_id="$3"
  cat <<EOF
${step}. Post ${content} to Slack channel ${channel_id} using
   mcp__claude_ai_Slack__slack_send_message (the channel_id argument is
   ${channel_id}).

   If the send fails, retry it inline a few times (up to 4 attempts total).
   Do NOT start a background timer or wait for a completion notification to
   fire a later retry: this is a non-interactive --print run with no further
   turns, so nothing will ever wake you and the run would stall until it is
   killed. Run the retries back to back, then stop.

   If every attempt still fails (e.g. the Slack write path is down), give up
   on delivery and, as the very LAST thing you output, print this marker on a
   line by itself, exactly:

     ${WORKER_DM_FAILED_SENTINEL}

   then print the full message body you could not send, so it is captured in
   the run log for recovery. Print the marker ONLY when the message was not
   delivered; never print it after a successful send.
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
  # Capture stdout via tee so we can both stream it to the log and scan it for
  # the DM-failure sentinel; PIPESTATUS[0] gives claude's exit, not tee's.
  local out_file
  out_file="$(mktemp "${TMPDIR:-/tmp}/${WORKER_STATE_NAME}-out.XXXXXX")"
  start_heartbeat 60 "$heartbeat_label"
  set +e
  caffeinate -i timeout --kill-after="$RUN_KILL_AFTER_SECONDS" \
    "$RUN_TIMEOUT_SECONDS" \
    claude --print \
      --session-id "$SESSION_ID" \
      "${permission_args[@]}" \
      --max-budget-usd "$MAX_BUDGET_USD" \
      --output-format text \
      "$prompt" | tee "$out_file"
  local exit_code=${PIPESTATUS[0]}
  set -e
  stop_heartbeat

  local dm_failed=0
  if grep -qF "$WORKER_DM_FAILED_SENTINEL" "$out_file"; then
    dm_failed=1
  fi
  rm -f "$out_file"

  if [[ $exit_code -eq 124 ]]; then
    log_error "${WORKER_STATE_NAME} timed out after ${RUN_TIMEOUT_SECONDS}s"
  elif [[ $exit_code -ne 0 ]]; then
    log_error "${WORKER_STATE_NAME} failed with exit code $exit_code"
  elif [[ $dm_failed -eq 1 ]]; then
    # Output was produced but Slack delivery failed; the body is in the log
    # above. Surface as a non-zero exit so the run isn't logged as success.
    log_error "${WORKER_STATE_NAME} produced output but could not deliver the Slack DM (write path down); undelivered body is in the log above. Resume: claude --resume ${SESSION_ID}"
    exit_code=3
  else
    log_success "${WORKER_STATE_NAME} finished (session $SESSION_ID)"
  fi

  exit "$exit_code"
}
