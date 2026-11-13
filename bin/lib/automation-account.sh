#!/bin/sh
# automation-account.sh - Run scheduled claude sessions under the automation
# account.
#
# The automation account signs in with /login to its own Claude Code config
# directory. Scheduled runs that use that directory count against the
# automation account's usage limits instead of the default login's.
# ai/install-claude-automation.sh creates the directory. A setup-token token
# cannot replace the login, because that token cannot load the claude.ai
# connectors that the workers send Slack messages through.
#
# Source this file after logging.sh. Call `use_automation_account` before
# running claude. The file stays POSIX sh, because the sh installer sources it
# to read AUTOMATION_CLAUDE_CONFIG_DIR.

AUTOMATION_CLAUDE_CONFIG_DIR="${HOME}/.claude-automation"

# automation_account_name
# Prints "email (organization)" for the account signed in to the automation
# config directory. Prints nothing when the directory is missing or not signed
# in. Always succeeds.
automation_account_name() {
  # Claude Code records the signed-in account under oauthAccount in the config
  # dir's .claude.json.
  jq -r '.oauthAccount // empty | "\(.emailAddress) (\(.organizationName))"' \
    "$AUTOMATION_CLAUDE_CONFIG_DIR/.claude.json" 2>/dev/null || true
}

# use_automation_account
# Exports CLAUDE_CONFIG_DIR when the automation config directory is signed in.
# Otherwise it leaves CLAUDE_CONFIG_DIR unchanged and logs a warning. The run
# then uses the default login.
use_automation_account() {
  automation_account=$(automation_account_name)
  if [ -n "$automation_account" ]; then
    export CLAUDE_CONFIG_DIR="$AUTOMATION_CLAUDE_CONFIG_DIR"
    log_info "Claude config: $CLAUDE_CONFIG_DIR, signed in as $automation_account"
  else
    log_warn "$AUTOMATION_CLAUDE_CONFIG_DIR is not signed in; using the default Claude login"
  fi
}

# record_last_session <state-dir> <session-id>
# Writes the session ID to last-session-id and CLAUDE_CONFIG_DIR to
# last-session-config-dir in the state directory. An empty
# last-session-config-dir means the default login. Each account keeps its own
# transcripts, so a resume needs both files. Call it after
# use_automation_account.
record_last_session() {
  printf '%s\n' "$2" >"$1/last-session-id"
  printf '%s\n' "${CLAUDE_CONFIG_DIR-}" >"$1/last-session-config-dir"
}

# last_session_config_dir <state-dir>
# Prints the config directory that record_last_session wrote. Prints nothing
# for the default login or when no run has written one.
last_session_config_dir() {
  cat "$1/last-session-config-dir" 2>/dev/null || true
}

# claude_resume_command <config-dir> <session-id>
# Prints a shell command that resumes the session under the account in the
# config directory. An empty config directory means the default login, and the
# command then sets no CLAUDE_CONFIG_DIR.
claude_resume_command() {
  if [ -z "$1" ]; then
    printf 'claude --resume %s\n' "$2"
    return
  fi
  case $1 in
    *[!A-Za-z0-9_./-]*)
      # Single quotes keep every character literal. Each ' in the directory
      # becomes '\''.
      set -- "'$(printf '%s' "$1" | sed "s/'/'\\\\''/g")'" "$2"
      ;;
  esac
  printf 'CLAUDE_CONFIG_DIR=%s claude --resume %s\n' "$1" "$2"
}
