#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh

info "Configuring GitHub MCP permissions…"

SETTINGS_FILE="$HOME/.claude/settings.json"

# Ensure settings file exists
if [ ! -f "$SETTINGS_FILE" ]; then
    echo '{"model": "sonnet"}' > "$SETTINGS_FILE"
    success "Created initial settings.json"
fi

if command -v jq > /dev/null 2>&1; then
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
    if jq -e '.permissions.allow' "$SETTINGS_FILE" > /dev/null 2>&1; then
        success "GitHub MCP permissions already configured"
    else
        # Validate JSON structure before merging
        if echo "$PERMISSIONS_CONFIG" | jq empty > /dev/null 2>&1; then
            # Merge permissions into existing settings
            if jq ". + $PERMISSIONS_CONFIG" "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp" 2>/dev/null; then
                # Validate the merged result
                if jq empty "${SETTINGS_FILE}.tmp" > /dev/null 2>&1; then
                    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
                    success "GitHub read-only MCP tools auto-approved"
                    info "Write operations (create/update/merge) will still require approval"
                else
                    rm -f "${SETTINGS_FILE}.tmp"
                    warning "Generated invalid JSON - permissions configuration skipped"
                fi
            else
                rm -f "${SETTINGS_FILE}.tmp"
                warning "Failed to merge permissions configuration"
            fi
        else
            warning "Invalid permissions JSON configuration - skipping"
        fi
    fi
else
    warning "jq not found - permissions configuration skipped"
    info "Install jq and re-run this script to configure permissions"
fi