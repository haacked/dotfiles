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
