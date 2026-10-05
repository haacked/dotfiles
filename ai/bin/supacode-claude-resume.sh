#!/usr/bin/env bash
# Resumes a Supacode pane's Claude Code session after a reboot.
#
# Usage:
#   supacode-claude-resume.sh hook      SessionStart and SessionEnd hook. Reads the hook input on stdin.
#   supacode-claude-resume.sh restore   Run by zshrc when a Supacode shell starts.
#
# Supacode gives a restored pane the same SUPACODE_SURFACE_ID after a reboot.
# It does not restore the Claude session that ran in the pane. The hook records
# each pane's session under the pane's surface ID.

set -uo pipefail

state_dir="$HOME/.local/state/claude-resume"
uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'

hook() {
  local input event session_id reason record other
  # Claude Code 2.1.289 sets CLAUDE_CODE_ENTRYPOINT to "cli" for interactive
  # sessions. `claude -p` sets "sdk-cli", even when it runs on a TTY.
  [[ "${SUPACODE_SURFACE_ID:-}" =~ $uuid_re && "${CLAUDE_CODE_ENTRYPOINT:-}" == cli ]] || return 0

  input=$(cat)
  {
    read -r event
    read -r session_id
    read -r reason
  } < <(jq -r '.hook_event_name // "", .session_id // "", .reason // ""' <<<"$input" 2>/dev/null)
  [[ "$session_id" =~ $uuid_re ]] || return 0
  record="$state_dir/$SUPACODE_SURFACE_ID.json"

  case "$event" in
  SessionStart)
    mkdir -p "$state_dir" || return 0
    # Only the pane that started or resumed a session last keeps a record of it.
    # Otherwise both panes would resume it when their worktree opens after a reboot.
    while IFS= read -r other; do
      [[ "$other" == "$record" ]] || rm -f "$other"
    done < <(grep -lF -- "$session_id" "$state_dir"/*.json 2>/dev/null)
    jq '{sessionId: .session_id, cwd, transcriptPath: .transcript_path}' <<<"$input" >"$record.$$" &&
      mv "$record.$$" "$record"
    rm -f "$record.$$"
    ;;
  SessionEnd)
    # /exit, Ctrl-D, and Ctrl-C report prompt_input_exit. A reboot or any other
    # signal reports other.
    [[ "$reason" == prompt_input_exit ]] || return 0
    [[ "$(jq -r '.sessionId // empty' "$record" 2>/dev/null)" == "$session_id" ]] && rm -f "$record"
    ;;
  esac
}

# A sessions file outlives a SIGKILLed Claude process. Pids are reused after a
# reboot. procStart holds the process start time in UTC, in the format of
# `ps -o lstart`.
session_is_live() { # session_id
  local config_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}" file pid proc_start
  while IFS= read -r file; do
    {
      read -r pid
      read -r proc_start
    } < <(jq -r --arg sid "$1" 'select(.sessionId == $sid) | .pid, (.procStart // "")' "$file" 2>/dev/null)
    [[ -n "$proc_start" ]] || continue
    [[ "$(TZ=UTC ps -o lstart= -p "$pid" 2>/dev/null | sed 's/ *$//')" == "$proc_start" ]] && return 0
  done < <(grep -lF -- "$1" "$config_dir"/sessions/*.json 2>/dev/null)
  return 1
}

session_title() { # transcript
  grep -E '"type":"(custom|ai)-title"' "$1" 2>/dev/null |
    jq -rs '(map(select(.type == "custom-title")) | last | .customTitle) // (map(select(.type == "ai-title")) | last | .aiTitle) // empty' 2>/dev/null
}

restore() {
  local record session_id cwd transcript title
  [[ "${SUPACODE_SURFACE_ID:-}" =~ $uuid_re ]] || return 0
  record="$state_dir/$SUPACODE_SURFACE_ID.json"
  [[ -f "$record" ]] || return 0

  {
    read -r session_id
    read -r cwd
    read -r transcript
  } < <(jq -r '.sessionId // "", .cwd // "", .transcriptPath // ""' "$record" 2>/dev/null)
  # `claude --resume ""` opens a picker that can resume an unrelated session. A
  # session that exited before its first prompt has no transcript to resume.
  if ! [[ "$session_id" =~ $uuid_re && -d "$cwd" && -f "$transcript" ]]; then
    rm -f "$record"
    return 0
  fi
  session_is_live "$session_id" && return 0

  title=$(session_title "$transcript")
  echo "Resuming Claude session \"${title:-$session_id}\" in $cwd. Press any key to cancel…"
  trap 'rm -f "$record"; exit 130' INT
  if read -r -s -n 1 -t 3; then
    rm -f "$record"
    return 0
  fi
  trap - INT
  cd "$cwd" && exec claude --resume "$session_id"
}

case "${1:-}" in
hook)
  hook
  exit 0
  ;;
restore) restore ;;
*)
  echo "usage: supacode-claude-resume.sh hook|restore" >&2
  exit 2
  ;;
esac
