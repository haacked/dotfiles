#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh
. $ZSH/ai/helpers/json-settings.sh
. $ZSH/ai/helpers/managed-links.sh

# Drop every hook this repo owns from settings.json, identified by its command
# path. Filtering happens at the individual hook level, so a hand-added hook
# sharing an element with a managed one survives; elements left empty are
# dropped. Inline lint/format hook commands carry no path marker and stay.
#
# Install runs this before merging too, not just uninstall: merge_json_settings
# dedupes arrays with `unique`, which collapses byte-identical elements only, so
# changing a shipped hook's command or timeout would otherwise leave the old
# entry firing alongside the new one.
prune_managed_hooks() { # settings_file
    prune_target="$1"
    [ -f "$prune_target" ] || return 0
    command -v jq > /dev/null 2>&1 || return 0
    prune_tmp=$(mktemp)
    if jq 'if .hooks then .hooks |= with_entries(.value |= (map(.hooks |= map(select((.command // "") | test("/\\.claude/skills/[^\"]*-detect\\.sh|/\\.dotfiles/ai/bin/") | not))) | map(select((.hooks | length) > 0)))) else . end' "$prune_target" > "$prune_tmp"; then
        mv "$prune_tmp" "$prune_target"
        return 0
    fi
    rm -f "$prune_tmp"
    return 1
}

# Uninstall function
uninstall_claude_config() {
    info "Uninstalling Claude configuration…"

    # Remove CLAUDE.md symlink
    if [ "$INSTALL_CLAUDE_MD" = "true" ]; then
        if [ -L ~/.claude/CLAUDE.md ]; then
            if remove_managed_link ~/.claude/CLAUDE.md "$ZSH/ai/AGENTS.md" "$ZSH/ai/CLAUDE.md"; then
                success "Removed CLAUDE.md symlink"
            fi
        elif [ -f ~/.claude/CLAUDE.md ]; then
            warning "~/.claude/CLAUDE.md is a regular file, not a symlink - skipping"
        fi
    fi

    # Remove agent symlinks
    if [ "$INSTALL_AGENTS" = "true" ]; then
        if [ -d ~/.claude/agents ]; then
            for agent in ~/.claude/agents/*.*; do
                remove_managed_link "$agent" "$ZSH/ai/agents/"
            done
            success "Removed agent symlinks"
        fi
    fi

    # Remove skill symlinks and contexts
    if [ "$INSTALL_SKILLS" = "true" ]; then
        if [ -d ~/.claude/skills ]; then
            # The glob must not be restricted to */, or a broken symlink left behind
            # by a renamed or deleted skill fails -d and survives the sweep.
            for skill in ~/.claude/skills/*; do
                remove_managed_link "$skill" "$ZSH/ai/skills/"
            done
            success "Removed skill symlinks"
        fi

        if [ -L ~/.claude/contexts ] && [ "$(readlink ~/.claude/contexts)" = "$ZSH/ai/contexts" ]; then
            rm -f ~/.claude/contexts
            success "Removed contexts symlink"
        fi
    fi

    if [ "$INSTALL_HOOKS" = "true" ]; then
        if prune_managed_hooks "$HOME/.claude/settings.json"; then
            success "Removed managed detect/bin hooks from settings.json"
        else
            warning "Could not update hooks in settings.json"
        fi
    fi

    echo ""
    success "Claude configuration uninstalled successfully!"
    info "Note: MCP servers, permissions, and inline lint/format hooks are not removed by uninstall"
}

# Parse command line options
UNINSTALL=false
INSTALL_CLAUDE_MD=true
INSTALL_AGENTS=true
INSTALL_SKILLS=true
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
    echo "  --claude-md-only, --instructions-only"
    echo "                      Install only the global instructions file"
    echo "  --agents-only       Install only agent files"
    echo "  --skills-only       Install only skills"
    echo "  --mcp-only          Install only MCP servers"
    echo "  --hooks-only        Install only Claude Code hooks"
    echo "  --permissions-only  Install only tool permissions"
    echo "  --no-claude-md, --no-instructions"
    echo "                      Skip the global instructions file"
    echo "  --no-agents         Skip agent files installation"
    echo "  --no-skills         Skip skills installation"
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
        --claude-md-only|--instructions-only)
            INSTALL_CLAUDE_MD=true
            INSTALL_AGENTS=false
            INSTALL_SKILLS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --agents-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=true
            INSTALL_SKILLS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --skills-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_SKILLS=true
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --mcp-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_SKILLS=false
            INSTALL_MCP=true
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --hooks-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_SKILLS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=true
            INSTALL_PERMISSIONS=false
            shift
            ;;
        --permissions-only)
            INSTALL_CLAUDE_MD=false
            INSTALL_AGENTS=false
            INSTALL_SKILLS=false
            INSTALL_MCP=false
            INSTALL_HOOKS=false
            INSTALL_PERMISSIONS=true
            shift
            ;;
        --no-claude-md|--no-instructions)
            INSTALL_CLAUDE_MD=false
            shift
            ;;
        --no-agents)
            INSTALL_AGENTS=false
            shift
            ;;
        --no-skills)
            INSTALL_SKILLS=false
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
    $ZSH/ai/skills/analyze-permissions/scripts/cleanup-settings-local.sh
    exit 0
fi

info "Installing Claude configuration…"

# Ensure ~/.claude directory exists
mkdir -p ~/.claude

# Symlink CLAUDE.md
if [ "$INSTALL_CLAUDE_MD" = "true" ]; then
    # A skipped link means every global instruction stops applying, so do not
    # announce an install that did not happen.
    if install_managed_link "$ZSH/ai/AGENTS.md" ~/.claude/CLAUDE.md "$ZSH/ai/"; then
        success "Installed CLAUDE.md"
    else
        info "Move or delete ~/.claude/CLAUDE.md and re-run to use the shared instructions."
    fi
fi

# Symlink agents
if [ "$INSTALL_AGENTS" = "true" ]; then
    mkdir -p ~/.claude/agents
    for agent in $ZSH/ai/agents/*.*; do
        agent_name=$(basename "$agent")
        destination=~/.claude/agents/"$agent_name"
        install_managed_link "$agent" "$destination" "$ZSH/ai/agents/"
    done
    success "Symlinked agents"
fi

# Symlink skills (directories, not files)
if [ "$INSTALL_SKILLS" = "true" ]; then
    mkdir -p ~/.claude/skills
    for skill_dir in $ZSH/ai/skills/*/; do
        [ -d "$skill_dir" ] || continue
        skill_name=$(basename "$skill_dir")
        destination=~/.claude/skills/"$skill_name"
        install_managed_link "$skill_dir" "$destination" "$ZSH/ai/skills/"
    done
    success "Symlinked skills"

    # Symlink contexts (for language-specific writing guidelines)
    install_managed_link "$ZSH/ai/contexts" ~/.claude/contexts "$ZSH/ai/contexts"
    success "Installed contexts"

    # Clean up old command symlinks that were migrated to skills
    MIGRATED_COMMANDS="note support standup analyze-permissions triage-issues squash security-audit"
    for cmd in $MIGRATED_COMMANDS; do
        if [ -L ~/.claude/commands/"$cmd".md ] || [ -f ~/.claude/commands/"$cmd".md ]; then
            rm -f ~/.claude/commands/"$cmd".md
        fi
    done
    success "Cleaned up migrated command symlinks"

    # Handoffs for directories outside a git repo moved to a provider-neutral home.
    # The filename hash is unchanged, so moving the directory is the whole migration;
    # without it the resolver reports every existing handoff as new.
    if [ -d ~/.claude/handoff ] && [ ! -d ~/.agents/handoff ]; then
        mkdir -p ~/.agents
        mv ~/.claude/handoff ~/.agents/handoff
        success "Migrated handoff documents to ~/.agents/handoff"
    fi
fi

. "$ZSH/ai/mcp-servers.sh"

# Install MCP servers
if [ "$INSTALL_MCP" = "true" ]; then
    info "Installing MCP servers…"

    # `claude mcp list` health-checks every configured server, so read it once
    # rather than once per entry.
    installed_servers=$(claude mcp list 2>/dev/null)

    # Process each server definition
    echo "$MCP_SERVERS" | grep -v "^$" | while IFS='|' read -r name transport description target; do
        # Skip empty lines
        [ -z "$name" ] && continue

        if echo "$installed_servers" | grep -q "^${name}:"; then
            success "${description} already installed"
            continue
        fi

        if [ "$transport" = "stdio" ] && ! stdio_command_available "${target%% *}"; then
            warning "${description} skipped: ${target%% *} not found"
            continue
        fi

        info "Installing ${description}…"

        if [ "$transport" = "http" ]; then
            claude mcp add --scope user --transport http "$name" "$target"
        else
            # The env args and the target are left unquoted on purpose: field
            # splitting turns them into separate arguments. IFS is back to the
            # default here, since the assignment applies only to `read`.
            # shellcheck disable=SC2086
            claude mcp add --scope user "$name" $(set_server_env "$name") -- $target
        fi

        if [ $? -eq 0 ]; then
            success "${description} installed"
        else
            error "${description} failed to install"
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

        # Keep only the most recent backups; this runs on every install so
        # backups accumulate indefinitely without pruning.
        # `tail -n +N` (start-from-line-N) is POSIX, unlike the obsolescent
        # `tail +N` form.
        KEEP_BACKUPS=5
        ls -t "${SETTINGS_FILE}".backup.* 2>/dev/null | tail -n "+$((KEEP_BACKUPS + 1))" | while IFS= read -r old_backup; do
            rm -f "$old_backup"
        done
    fi

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
      },
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotfiles/ai/bin/enforce-create-pr-skill.sh",
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
          }
        ]
      },
      {
        "matcher": "Skill",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotfiles/ai/bin/log-command.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "if [ -f Cargo.toml ]; then cargo fmt 2>/dev/null || true; fi",
            "timeout": 30
          }
        ]
      }
    ],
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/handoff/scripts/handoff-detect.sh",
            "timeout": 5
          }
        ]
      },
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.claude/skills/followup/scripts/followup-detect.sh",
            "timeout": 5
          }
        ]
      }
    ],
    "UserPromptSubmit": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "~/.dotfiles/ai/bin/log-command.sh",
            "timeout": 5
          }
        ]
      }
    ]
  }
}
EOF
    )

    prune_managed_hooks "$SETTINGS_FILE" || warning "Could not prune managed hooks before merging"

    # Always run the merge. Do not re-add a `jq -e '.hooks.PostToolUse'` guard:
    # it would skip the merge for users who already have any PostToolUse entry,
    # preventing newly-added hook categories (SessionStart, new PreToolUse
    # matchers, etc.) from ever landing on upgrade. merge_json_settings is
    # idempotent (jq deep-merge + `unique` on arrays), so re-running is safe.
    if merge_json_settings "$SETTINGS_FILE" "$HOOKS_CONFIG" "hooks"; then
        success "Configured Claude Code hooks"
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
