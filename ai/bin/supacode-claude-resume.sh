#!/usr/bin/env bash
# Resumes the Claude Code sessions that ran in Supacode panes.
#
# Usage:
#   supacode-claude-resume.sh hook                     SessionStart and SessionEnd hook. Reads the hook input on stdin.
#   supacode-claude-resume.sh restore                  Run by zshrc when a Supacode shell starts.
#   supacode-claude-resume.sh restore-all [--dry-run]  Run by hand after Supacode relaunches.
#
# The hook records each pane's session under the pane's surface ID. When
# Supacode restores a pane with its old SUPACODE_SURFACE_ID, restore resumes the
# pane's session in it. Supacode does not always restore its panes. restore-all
# opens a new tab for each session that ended when Supacode last quit.

set -uo pipefail

state_dir="$HOME/.local/state/claude-resume"
uuid_re='^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$'
# A Supacode quit ends all of its sessions within a few seconds.
quit_spread_seconds=60
start_timeout="${CLAUDE_RESUME_START_TIMEOUT:-60}"

usage() {
  echo "usage: supacode-claude-resume.sh hook|restore|restore-all [--dry-run]" >&2
  exit 2
}

update_record() { # record jq_args...
  local record="$1"
  shift
  jq "$@" >"$record.$$" && mv "$record.$$" "$record"
  rm -f "$record.$$"
}

# shellcheck disable=SC2016 # update_record takes jq programs, which name jq variables with $.
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
    # SUPACODE_SOCKET_PATH names the Supacode process that owns the pane.
    update_record "$record" --arg socket "${SUPACODE_SOCKET_PATH:-}" \
      '{sessionId: .session_id, cwd, transcriptPath: .transcript_path, supacodeSocket: $socket}' <<<"$input"
    ;;
  SessionEnd)
    [[ "$(jq -r '.sessionId // empty' "$record" 2>/dev/null)" == "$session_id" ]] || return 0
    # /exit, Ctrl-D, and Ctrl-C report prompt_input_exit. A closed tab, a
    # Supacode quit, a reboot, or any other signal reports other.
    if [[ "$reason" == prompt_input_exit ]]; then
      rm -f "$record"
    else
      update_record "$record" --argjson now "$(date +%s)" '.endedAt = $now' "$record"
    fi
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

session_title() { # transcript fallback
  grep -E '"type":"(custom|ai)-title"' "$1" 2>/dev/null |
    jq -rs --arg fallback "$2" '(map(select(.type == "custom-title")) | last | .customTitle) // (map(select(.type == "ai-title")) | last | .aiTitle) // $fallback' 2>/dev/null
}

# Sets session_id, cwd, transcript, socket, and ended in the caller's scope.
read_record() { # record
  {
    read -r session_id
    read -r cwd
    read -r transcript
    read -r socket
    read -r ended
  } < <(jq -r '.sessionId // "", .cwd // "", .transcriptPath // "", .supacodeSocket // "", .endedAt // ""' "$1" 2>/dev/null)
}

# `claude --resume ""` opens a picker that can resume an unrelated session. A
# session that exited before its first prompt has no transcript to resume.
is_resumable() { # session_id cwd transcript
  [[ "$1" =~ $uuid_re && -d "$2" && -f "$3" ]]
}

restore() {
  local record session_id cwd transcript socket ended title
  [[ "${SUPACODE_SURFACE_ID:-}" =~ $uuid_re ]] || return 0
  record="$state_dir/$SUPACODE_SURFACE_ID.json"
  [[ -f "$record" ]] || return 0

  read_record "$record"
  if ! is_resumable "$session_id" "$cwd" "$transcript"; then
    rm -f "$record"
    return 0
  fi
  session_is_live "$session_id" && return 0

  title=$(session_title "$transcript" "$session_id")
  echo "Resuming Claude session \"$title\" in $cwd. Press any key to cancel…"
  trap 'rm -f "$record"; exit 130' INT
  if read -r -s -n 1 -t 3; then
    rm -f "$record"
    return 0
  fi
  trap - INT
  cd "$cwd" && exec claude --resume "$session_id"
}

wait_until_live() { # session_id
  local deadline=$((SECONDS + start_timeout))
  until session_is_live "$1"; do
    ((SECONDS < deadline)) || return 1
    sleep 1
  done
}

restore_all() { # dry_run
  local dry_run=$1 sockets worktree_list id path file session_id cwd transcript socket ended
  local newest=0 i j worktree best_len title
  local -a worktree_ids=() worktree_paths=() sids=() cwds=() transcripts=() ends=()

  sockets=$(supacode socket) || {
    echo "restore-all: \`supacode socket\` failed. Is Supacode running?" >&2
    return 1
  }
  worktree_list=$(supacode worktree list --not-archived) || {
    echo "restore-all: \`supacode worktree list\` failed." >&2
    return 1
  }
  # A worktree ID is the worktree's URL-encoded path with a trailing slash.
  while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    path=$(printf '%b' "${id//%/\\x}")
    worktree_ids+=("$id")
    worktree_paths+=("${path%/}")
  done <<<"$worktree_list"

  for file in "$state_dir"/*.json; do
    [[ -f "$file" ]] || continue
    read_record "$file"
    [[ "$ended" =~ ^[0-9]+$ ]] || continue
    if ! is_resumable "$session_id" "$cwd" "$transcript"; then
      $dry_run || rm -f "$file"
      continue
    fi
    # A session of a running Supacode ended because its tab closed.
    [[ -n "$socket" ]] && grep -qxF -- "$socket" <<<"$sockets" && continue
    [[ " ${sids[*]-} " == *" $session_id "* ]] && continue
    session_is_live "$session_id" && continue
    sids+=("$session_id")
    cwds+=("$cwd")
    transcripts+=("$transcript")
    ends+=("$ended")
    ((ended > newest)) && newest=$ended
  done

  if ((${#sids[@]} == 0)); then
    echo "No Claude sessions to restore."
    return 0
  fi

  for i in "${!sids[@]}"; do
    ((ends[i] >= newest - quit_spread_seconds)) || continue
    session_id=${sids[i]}
    cwd=${cwds[i]}
    # A session can start in a subdirectory of its worktree.
    worktree=""
    best_len=0
    for j in "${!worktree_paths[@]}"; do
      path=${worktree_paths[j]}
      [[ "$cwd" == "$path" || "$cwd" == "$path"/* ]] || continue
      ((${#path} > best_len)) || continue
      worktree=${worktree_ids[j]}
      best_len=${#path}
    done
    if [[ -z "$worktree" ]]; then
      echo "Skipping $cwd: no Supacode worktree contains it."
      continue
    fi

    title=$(session_title "${transcripts[i]}" "$session_id")
    if $dry_run; then
      echo "Would resume \"$title\" in $cwd"
      continue
    fi
    echo "Resuming \"$title\" in $cwd"
    # A new shell's direnv activation can take minutes while a relaunched
    # Supacode is busy. Opening one tab at a time keeps the shells from
    # competing with each other for the CPU.
    if ! supacode tab new -w "$worktree" -i "cd $(printf '%q' "$cwd") && claude --resume $session_id" --background >/dev/null; then
      echo "Supacode could not open a tab for \"$title\"."
    elif ! wait_until_live "$session_id"; then
      echo "\"$title\" did not start within ${start_timeout}s."
    fi
  done
}

case "${1:-}" in
hook)
  hook
  exit 0
  ;;
restore) restore ;;
restore-all)
  case "${2-}" in
  "") restore_all false ;;
  --dry-run) restore_all true ;;
  *) usage ;;
  esac
  ;;
*) usage ;;
esac
