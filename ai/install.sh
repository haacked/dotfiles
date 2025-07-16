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
            # Check and add each MCP server individually
            # Check for posthog-db
            if jq -e '.mcpServers."posthog-db"' ~/.claude.json >/dev/null 2>&1; then
                echo "MCP server 'posthog-db' already configured in ~/.claude.json"
            else
                # Add posthog-db configuration
                jq -s '.[0] * {"mcpServers": (.[0].mcpServers // {} | . + {"posthog-db": .[1].mcpServers."posthog-db"})}' ~/.claude.json $ZSH/ai/mcp-servers.json > ~/.claude.json.tmp
                mv ~/.claude.json.tmp ~/.claude.json
                echo "Added posthog-db MCP server configuration to ~/.claude.json"
            fi

            # Check for github
            if jq -e '.mcpServers."github"' ~/.claude.json >/dev/null 2>&1; then
                echo "MCP server 'github' already configured in ~/.claude.json"
            else
                # Add github configuration
                jq -s '.[0] * {"mcpServers": (.[0].mcpServers // {} | . + {"github": .[1].mcpServers."github"})}' ~/.claude.json $ZSH/ai/mcp-servers.json > ~/.claude.json.tmp
                mv ~/.claude.json.tmp ~/.claude.json
                echo "Added github MCP server configuration to ~/.claude.json"
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