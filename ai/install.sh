#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh
. $ZSH/ai/helpers/json-settings.sh

info "Installing Claude configuration…"

# Ensure ~/.claude directory exists
mkdir -p ~/.claude

# Copy CLAUDE.md
cp $ZSH/ai/CLAUDE.md ~/.claude/CLAUDE.md
success "Copied CLAUDE.md"

# Copy agents
cp $ZSH/ai/agents/*.* ~/.claude/agents/
success "Copied agents"

# Define MCP servers as a list of entries
# Format: "name|description|command"
MCP_SERVERS="
github|GitHub API access|npx @modelcontextprotocol/server-github
posthog-db|PostHog database connection|/Users/haacked/.local/bin/postgres-mcp --access-mode=restricted
puppeteer|Puppeteer web automation|npx -y @modelcontextprotocol/server-puppeteer
memory|Persistent memory across sessions|npx -y @modelcontextprotocol/server-memory
git|Structured git operations|npx -y @modelcontextprotocol/server-git
spelungit|Git history semantic search|/Users/haacked/dev/haacked/spelungit/venv/bin/python
"

# Special environment variables for specific servers
set_server_env() {
    local server_name="$1"
    case "$server_name" in
        posthog-db)
            echo "-e DATABASE_URI=postgresql://posthog:posthog@localhost:5432/posthog"
            ;;
        spelungit)
            echo "-e PYTHONPATH=/Users/haacked/dev/haacked/spelungit/src -- -m spelungit.lite_server"
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

# Configure Claude Code hooks
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

# Configure terminal bell notifications (global config, not settings.json)
info "Configuring terminal bell notifications…"
claude config set -g preferredNotifChannel terminal_bell
success "Terminal bell notifications enabled"

# Configure tool permissions
$ZSH/ai/configure-tool-permissions.sh

echo ""
success "Claude configuration installed successfully!"