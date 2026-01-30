#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh
. $ZSH/ai/helpers/json-settings.sh

# Uninstall function
uninstall_claude_config() {
    info "Uninstalling Claude configuration…"

    # Remove CLAUDE.md symlink
    if [ "$INSTALL_CLAUDE_MD" = "true" ]; then
        if [ -L ~/.claude/CLAUDE.md ]; then
            rm -f ~/.claude/CLAUDE.md
            success "Removed CLAUDE.md symlink"
        elif [ -f ~/.claude/CLAUDE.md ]; then
            warning "~/.claude/CLAUDE.md is a regular file, not a symlink - skipping"
        fi
    fi

    # Remove agent symlinks
    if [ "$INSTALL_AGENTS" = "true" ]; then
        if [ -d ~/.claude/agents ]; then
            for agent in ~/.claude/agents/*.*; do
                if [ -L "$agent" ]; then
                    rm -f "$agent"
                fi
            done
            success "Removed agent symlinks"
        fi
    fi

    # Remove command symlinks
    if [ "$INSTALL_COMMANDS" = "true" ]; then
        if [ -d ~/.claude/commands ]; then
            for cmd in ~/.claude/commands/*.md; do
                if [ -L "$cmd" ]; then
                    rm -f "$cmd"
                fi
            done
            success "Removed command symlinks"
        fi

        # Remove contexts symlink
        if [ -L ~/.claude/contexts ]; then
            rm -f ~/.claude/contexts
            success "Removed contexts symlink"
        fi
    fi

    echo ""
    success "Claude configuration uninstalled successfully!"
    info "Note: MCP servers, hooks, and permissions are not removed by uninstall"
}

# Parse command line options
UNINSTALL=false
INSTALL_CLAUDE_MD=true
INSTALL_AGENTS=true
INSTALL_COMMANDS=true
INSTALL_MCP=true
INSTALL_HOOKS=true
INSTALL_PERMISSIONS=true
CLEANUP_ONLY=false

show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Install Claude configuration components selectively or all at once (default)."
    echo ""
    echo "Options:"
    echo "  --uninstall         Remove symlinks for file-based components"
    echo "  --cleanup           Clean up redundant entries in settings.local.json"
    echo "  --claude-md-only    Install only CLAUDE.md file"
    echo "  --agents-only       Install only agent files"
    echo "  --commands-only     Install only slash commands"
    echo "  --mcp-only          Install only MCP servers"
    echo "  --hooks-only        Install only Claude Code hooks"
    echo "  --permissions-only  Install only tool permissions"
    echo "  --no-claude-md      Skip CLAUDE.md installation"
    echo "  --no-agents         Skip agent files installation"
    echo "  --no-commands       Skip slash commands installation"
    echo "  --no-mcp            Skip MCP servers installation"
    echo "  --no-hooks          Skip Claude Code hooks installation"
    echo "  --no-permissions    Skip tool permissions configuration"
    echo "  -h, --help          Show this help message"
    echo ""
    echo "Examples:"
    echo "  $0                      # Install everything (default)"
    echo "  $0 --claude-md-only     # Install only CLAUDE.md"
    echo "  $0 --agents-only        # Install only agent files"
    echo "  $0 --no-mcp             # Install everything except MCP servers"
    echo "  $0 --uninstall          # Remove all symlinks"
    echo "  $0 --uninstall --agents-only  # Remove only agent symlinks"
    echo "  $0 --cleanup            # Clean up settings.local.json cruft"
}

# Parse arguments
while [ $# -gt 0 ]; do
    case $1 in
        --uninstall)
            UNINSTALL=true
            shift
            ;;
        --cleanup)
            CLEANUP_ONLY=true
            shift
            ;;
        --claude-md-only)
            INSTALL_CLAUDE_MD=true
            INSTALL_AGENTS=false
            INSTALL_COMMANDS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --agents-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=true
            INSTALL_COMMANDS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --commands-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_COMMANDS=true
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --mcp-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_COMMANDS=false
            INSTALL_MCP=true
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --hooks-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_COMMANDS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=true
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --permissions-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_COMMANDS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=true
            shift
            ;;
        --no-claude-md)
            INSTALL_CLAUDE_MD=false
            shift
            ;;
        --no-agents)
            INSTALL_AGENTS=false
            shift
            ;;
        --no-commands)
            INSTALL_COMMANDS=false
            shift
            ;;
        --no-mcp)
            INSTALL_MCP=false
            shift
            ;;
        --no-hooks)
            INSTALL_HOOKS=false
            shift
            ;;
        --no-permissions)
            INSTALL_PERMISSIONS=false
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
    esac
done

# If uninstall flag is set, uninstall and exit
if [ "$UNINSTALL" = "true" ]; then
    uninstall_claude_config
    exit 0
fi

# If cleanup flag is set, run cleanup and exit
if [ "$CLEANUP_ONLY" = "true" ]; then
    $ZSH/ai/bin/cleanup-settings-local.sh
    exit 0
fi

info "Installing Claude configuration…"

# Ensure ~/.claude directory exists
mkdir -p ~/.claude

# Symlink CLAUDE.md
if [ "$INSTALL_CLAUDE_MD" = "true" ]; then
    rm -f ~/.claude/CLAUDE.md
    ln -sf $ZSH/ai/CLAUDE.md ~/.claude/CLAUDE.md
    success "Symlinked CLAUDE.md"
fi

# Symlink agents
if [ "$INSTALL_AGENTS" = "true" ]; then
    mkdir -p ~/.claude/agents
    for agent in $ZSH/ai/agents/*.*; do
        agent_name=$(basename "$agent")
        rm -f ~/.claude/agents/"$agent_name"
        ln -sf "$agent" ~/.claude/agents/"$agent_name"
    done
    success "Symlinked agents"
fi

# Symlink commands
if [ "$INSTALL_COMMANDS" = "true" ]; then
    mkdir -p ~/.claude/commands
    for cmd in $ZSH/ai/commands/*.md; do
        [ -e "$cmd" ] || continue  # Skip if no files match
        cmd_name=$(basename "$cmd")
        rm -f ~/.claude/commands/"$cmd_name"
        ln -sf "$cmd" ~/.claude/commands/"$cmd_name"
    done
    success "Symlinked commands"
fi

# Symlink contexts (for language-specific writing guidelines)
if [ "$INSTALL_COMMANDS" = "true" ]; then
    rm -f ~/.claude/contexts
    ln -sf $ZSH/ai/contexts ~/.claude/contexts
    success "Symlinked contexts"
fi

# Define MCP servers as a list of entries
# Format: "name|description|command"
MCP_SERVERS="
posthog-db|PostHog database connection|/Users/haacked/.local/bin/postgres-mcp --access-mode=restricted
memory|Persistent memory across sessions|npx -y @modelcontextprotocol/server-memory
git|Structured git operations|npx -y @modelcontextprotocol/server-git
grafana|Grafana MCP server|/Users/haacked/.dotfiles/bin/mcp-grafana-wrapper.sh
"

# Special environment variables for specific servers
set_server_env() {
    local server_name="$1"
    case "$server_name" in
        posthog-db)
            echo "-e DATABASE_URI=postgresql://posthog:posthog@localhost:5432/posthog"
            ;;
        *)
            echo ""
            ;;
    esac
}

# Install MCP servers
if [ "$INSTALL_MCP" = "true" ]; then
    info "Installing MCP servers…"

    # Process each server definition
    echo "$MCP_SERVERS" | grep -v "^$" | while IFS='|' read -r name description command; do
        # Skip empty lines
        [ -z "$name" ] && continue

        # Check if server already exists
        if ! claude mcp list 2>/dev/null | grep -q "^${name}:"; then
            info "Installing ${description}…"

            # Get any special environment variables
            env_args=$(set_server_env "$name")

            # Build and execute the command
            if [ -n "$env_args" ]; then
                eval "claude mcp add --scope user ${name} ${env_args} -- ${command}"
            else
                claude mcp add --scope user ${name} -- ${command}
            fi

            success "${description} installed"
        else
            success "${description} already installed"
        fi
    done
fi

# Configure Claude Code hooks
if [ "$INSTALL_HOOKS" = "true" ]; then
    info "Configuring Claude Code hooks…"

    SETTINGS_FILE="$HOME/.claude/settings.json"

    # Create backup if settings file exists
    if [ -f "$SETTINGS_FILE" ]; then
        cp "$SETTINGS_FILE" "${SETTINGS_FILE}.backup.$(date +%Y%m%d_%H%M%S)"
        success "Backed up existing settings.json"
    fi

    # Check if hooks are already configured
    if [ -f "$SETTINGS_FILE" ] && command -v jq > /dev/null 2>&1 && jq -e '.hooks.PostToolUse' "$SETTINGS_FILE" > /dev/null 2>&1; then
        success "Claude Code hooks already configured"
    else
        # Create minimal settings file if it doesn't exist
        if [ ! -f "$SETTINGS_FILE" ]; then
            echo '{"model": "sonnet"}' > "$SETTINGS_FILE"
            success "Created initial settings.json"
        fi

        # Create hooks configuration with separate matchers for each tool
        HOOKS_CONFIG=$(cat <<'EOF'
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Edit|Write",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotfiles/ai/bin/lang-context",
            "timeout": 5
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Edit",
        "hooks": [
          {
            "type": "command",
            "command": "if [ -n \"$CLAUDE_FILE_PATHS\" ]; then for file in $CLAUDE_FILE_PATHS; do if [[ \"$file\" == *.md || \"$file\" == *.markdown ]]; then markdownlint \"$file\" || echo \"Markdownlint failed for $file\"; fi; done; fi",
            "timeout": 30
          },
          {
            "type": "command",
            "command": "if [ -n \"$CLAUDE_FILE_PATHS\" ]; then for file in $CLAUDE_FILE_PATHS; do if [[ \"$file\" == *.py ]]; then if command -v ruff > /dev/null 2>&1; then ruff format \"$file\" || echo \"Ruff format failed for $file\"; else echo \"Ruff not installed - skipping Python formatting\"; fi; fi; done; fi",
            "timeout": 30
          },
          {
            "type": "command",
            "command": "if [ -d .github/workflows ]; then if grep -r 'mypy' .github/workflows/ > /dev/null 2>&1; then if command -v mypy > /dev/null 2>&1; then echo 'Running mypy...'; mypy .; else echo 'MyPy configured in CI but not installed locally'; fi; fi; fi",
            "timeout": 120
          }
        ]
      },
      {
        "matcher": "Write",
        "hooks": [
          {
            "type": "command",
            "command": "if [ -n \"$CLAUDE_FILE_PATHS\" ]; then for file in $CLAUDE_FILE_PATHS; do if [[ \"$file\" == *.md || \"$file\" == *.markdown ]]; then markdownlint \"$file\" || echo \"Markdownlint failed for $file\"; fi; done; fi",
            "timeout": 30
          },
          {
            "type": "command",
            "command": "if [ -n \"$CLAUDE_FILE_PATHS\" ]; then for file in $CLAUDE_FILE_PATHS; do if [[ \"$file\" == *.py ]]; then if command -v ruff > /dev/null 2>&1; then ruff format \"$file\" || echo \"Ruff format failed for $file\"; else echo \"Ruff not installed - skipping Python formatting\"; fi; fi; done; fi",
            "timeout": 30
          },
          {
            "type": "command",
            "command": "if [ -d .github/workflows ]; then if grep -r 'mypy' .github/workflows/ > /dev/null 2>&1; then if command -v mypy > /dev/null 2>&1; then echo 'Running mypy...'; mypy .; else echo 'MyPy configured in CI but not installed locally'; fi; fi; fi",
            "timeout": 120
          }
        ]
      },
      {
        "matcher": "MultiEdit",
        "hooks": [
          {
            "type": "command",
            "command": "if [ -n \"$CLAUDE_FILE_PATHS\" ]; then for file in $CLAUDE_FILE_PATHS; do if [[ \"$file\" == *.md || \"$file\" == *.markdown ]]; then markdownlint \"$file\" || echo \"Markdownlint failed for $file\"; fi; done; fi",
            "timeout": 30
          },
          {
            "type": "command",
            "command": "if [ -n \"$CLAUDE_FILE_PATHS\" ]; then for file in $CLAUDE_FILE_PATHS; do if [[ \"$file\" == *.py ]]; then if command -v ruff > /dev/null 2>&1; then ruff format \"$file\" || echo \"Ruff format failed for $file\"; else echo \"Ruff not installed - skipping Python formatting\"; fi; fi; done; fi",
            "timeout": 30
          },
          {
            "type": "command",
            "command": "if [ -d .github/workflows ]; then if grep -r 'mypy' .github/workflows/ > /dev/null 2>&1; then if command -v mypy > /dev/null 2>&1; then echo 'Running mypy...'; mypy .; else echo 'MyPy configured in CI but not installed locally'; fi; fi; fi",
            "timeout": 120
          }
        ]
      }
    ]
  }
}
EOF
        )

        # Merge hooks configuration using helper function
        if merge_json_settings "$SETTINGS_FILE" "$HOOKS_CONFIG" "hooks"; then
            success "Configured Claude Code hooks"
        fi
    fi
fi

# Configure terminal bell notifications (global config, not settings.json)
if [ "$INSTALL_HOOKS" = "true" ]; then
    info "Configuring terminal bell notifications…"
    # Note: The 'claude config' command has been removed in recent versions
    # Terminal bell notifications may need to be configured manually via settings
    # claude config set -g preferredNotifChannel terminal_bell
    success "Terminal bell notifications skipped (config command deprecated)"
fi

# Configure tool permissions
if [ "$INSTALL_PERMISSIONS" = "true" ]; then
    $ZSH/ai/configure-tool-permissions.sh
fi

echo ""
success "Claude configuration installed successfully!"