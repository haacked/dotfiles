#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh
. $ZSH/ai/helpers/json-settings.sh

info "Configuring GitHub MCP permissions…"

SETTINGS_FILE="$HOME/.claude/settings.json"

# Define permissions configuration
PERMISSIONS_CONFIG=$(cat <<'EOF'
{
  "permissions": {
    "allow": [
      "mcp__github__get_file_contents",
      "mcp__github__get_issue",
      "mcp__github__get_pull_request",
      "mcp__github__get_pull_request_comments",
      "mcp__github__get_pull_request_files",
      "mcp__github__get_pull_request_reviews",
      "mcp__github__get_pull_request_status",
      "mcp__github__list_commits",
      "mcp__github__list_issues",
      "mcp__github__list_pull_requests",
      "mcp__github__search_code",
      "mcp__github__search_issues",
      "mcp__github__search_repositories",
      "mcp__github__search_users"
    ]
  }
}
EOF
)

# Check if permissions are already configured
if command -v jq > /dev/null 2>&1 && jq -e '.permissions.allow' "$SETTINGS_FILE" > /dev/null 2>&1; then
    success "GitHub MCP permissions already configured"
else
    # Merge permissions configuration using helper function
    if merge_json_settings "$SETTINGS_FILE" "$PERMISSIONS_CONFIG" "GitHub MCP permissions"; then
        success "GitHub read-only MCP tools auto-approved"
        info "Write operations (create/update/merge) will still require approval"
    fi
fi