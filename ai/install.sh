#!/bin/sh

export ZSH=$HOME/.dotfiles

# Ensure ~/.claude directory exists
mkdir -p ~/.claude

# Copy Claude configuration files
cp $ZSH/ai/CLAUDE.md ~/.claude/CLAUDE.md
cp $ZSH/ai/settings.json ~/.claude/settings.json

# Handle MCP servers configuration
if [ -f "$ZSH/ai/mcp-servers.json" ]; then
    # Check if ~/.claude.json exists
    if [ -f ~/.claude.json ]; then
        # Backup existing file
        cp ~/.claude.json ~/.claude.json.backup
        
        # Merge MCP servers configuration into existing .claude.json
        # This requires jq to be installed
        if command -v jq >/dev/null 2>&1; then
            # First check if posthog-db already exists in the current config
            if jq -e '.mcpServers."posthog-db"' ~/.claude.json >/dev/null 2>&1; then
                echo "MCP server 'posthog-db' already configured in ~/.claude.json"
            else
                # Merge only if posthog-db doesn't exist
                jq -s '.[0] * {"mcpServers": (.[0].mcpServers // {} | . + .[1].mcpServers)}' ~/.claude.json $ZSH/ai/mcp-servers.json > ~/.claude.json.tmp
                mv ~/.claude.json.tmp ~/.claude.json
                echo "Added MCP servers configuration to ~/.claude.json"
            fi
        else
            echo "Warning: jq is not installed. Cannot merge MCP configuration."
            echo "To install jq: brew install jq"
            echo "MCP configuration file is at: $ZSH/ai/mcp-servers.json"
        fi
    else
        # If ~/.claude.json doesn't exist, just copy the MCP config
        cp $ZSH/ai/mcp-servers.json ~/.claude.json
        echo "Created ~/.claude.json with MCP servers configuration"
    fi
fi