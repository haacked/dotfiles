#!/bin/sh
# install-claude-automation.sh - Build the Claude config directory that the
# scheduled jobs in bin/ run under (see bin/lib/automation-account.sh).
#
# The directory links back to the shared parts of ~/.claude. The jobs load the
# same instructions, agents, skills, settings, plugins, and session transcripts
# as the default login. Its login and .claude.json stay separate from
# ~/.claude. The script installs the MCP servers into it, because Claude Code
# stores them in .claude.json.

set -eu

DOTFILES_ROOT="$(cd "$(dirname "$0")/.." && pwd)"

# shellcheck source=/dev/null
. "$DOTFILES_ROOT/ai/helpers/output.sh"
# shellcheck source=/dev/null
. "$DOTFILES_ROOT/ai/helpers/managed-links.sh"
# shellcheck source=/dev/null
. "$DOTFILES_ROOT/bin/lib/automation-account.sh"

usage() {
    echo "Usage: $0 [-h|--help]"
    echo ""
    echo "Create $AUTOMATION_CLAUDE_CONFIG_DIR for the automation account, link it to the"
    echo "shared parts of ~/.claude, and install the MCP servers into it."
}

if [ $# -gt 0 ]; then
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        *)
            usage >&2
            exit 1
            ;;
    esac
fi

# Claude Code creates projects and plugins on first use. Creating them in
# ~/.claude first gives the links a target, so the automation dir never gets
# its own copies.
mkdir -p "$AUTOMATION_CLAUDE_CONFIG_DIR" "$HOME/.claude/projects" "$HOME/.claude/plugins"
info "Linking $AUTOMATION_CLAUDE_CONFIG_DIR to ~/.claude…"

# The list leaves out .claude.json and the credentials, because they belong to
# the account.
for name in CLAUDE.md agents commands plugins projects settings.json skills; do
    [ -e "$HOME/.claude/$name" ] || continue
    if install_managed_link "$HOME/.claude/$name" "$AUTOMATION_CLAUDE_CONFIG_DIR/$name" "$HOME/.claude/"; then
        success "Linked $name"
    fi
done

CLAUDE_CONFIG_DIR="$AUTOMATION_CLAUDE_CONFIG_DIR" "$DOTFILES_ROOT/ai/install-claude.sh" --mcp-only

echo ""
info "Next, sign the directory in to the automation account:"
echo "  CLAUDE_CONFIG_DIR=$AUTOMATION_CLAUDE_CONFIG_DIR claude"
echo "Run /login, confirm the account with /status, and authenticate any server /mcp lists as needing it."
