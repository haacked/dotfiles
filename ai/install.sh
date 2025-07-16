#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh

info "Installing Claude configuration…"

# Ensure ~/.claude directory exists
mkdir -p ~/.claude

# Copy CLAUDE.md
cp $ZSH/ai/CLAUDE.md ~/.claude/CLAUDE.md
success "Copied CLAUDE.md"

# Define MCP servers as a list of entries
# Format: "name|description|command"
MCP_SERVERS="
github|GitHub API access|npx @modelcontextprotocol/server-github
posthog-db|PostHog database connection|/Users/haacked/.local/bin/postgres-mcp --access-mode=restricted
puppeteer|Puppeteer web automation|npx -y @modelcontextprotocol/server-puppeteer
memory|Persistent memory across sessions|npx -y @modelcontextprotocol/server-memory
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
            claude mcp add --scope user ${name} ${command}
        fi
        
        success "${description} installed"
    else
        success "${description} already installed"
    fi
done

echo ""
success "Claude configuration installed successfully!"
echo ""
warning "Tool permissions must be configured manually in Claude settings."
info "To configure permissions, edit ~/.claude/settings.json"