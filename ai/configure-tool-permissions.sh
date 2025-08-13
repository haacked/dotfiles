#!/bin/sh

export ZSH=$HOME/.dotfiles

# Source helper functions
. $ZSH/ai/helpers/output.sh
. $ZSH/ai/helpers/json-settings.sh

info "Configuring MCP permissions…"

SETTINGS_FILE="$HOME/.claude/settings.json"

# Define comprehensive MCP permissions configuration
# Auto-approve safe read-only operations while requiring approval for write/dangerous operations
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
      "mcp__github__search_users",
      "mcp__posthog-db__list_schemas",
      "mcp__posthog-db__list_objects",
      "mcp__posthog-db__get_object_details",
      "mcp__posthog-db__explain_query",
      "mcp__posthog-db__analyze_workload_indexes",
      "mcp__posthog-db__analyze_query_indexes",
      "mcp__posthog-db__analyze_db_health",
      "mcp__posthog-db__get_top_queries",
      "mcp__posthog-db__execute_sql",
      "mcp__memory__read_graph",
      "mcp__memory__search_nodes",
      "mcp__memory__open_nodes",
      "mcp__puppeteer__puppeteer_navigate",
      "mcp__puppeteer__puppeteer_screenshot",
      "Bash(mypy:*)",
      "Bash(python -m mypy:*)",
      "Bash(pytest:*)",
      "Bash(python -m pytest:*)",
      "Bash(./bin/fmt:*)",
      "Bash(bin/fmt:*)",
      "Bash(DJANGO_SETTINGS_MODULE=* python -m pytest:*)",
      "Bash(DJANGO_SETTINGS_MODULE=* mypy:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(ruff check:*)"
    ]
  }
}
EOF
)

# Check if MCP permissions are already configured by looking for a specific MCP tool
if command -v jq > /dev/null 2>&1 && jq -e '.permissions.allow[] | select(. == "mcp__github__get_file_contents")' "$SETTINGS_FILE" > /dev/null 2>&1; then
    success "MCP permissions already configured"
else
    # Merge permissions configuration using helper function
    if merge_json_settings "$SETTINGS_FILE" "$PERMISSIONS_CONFIG" "MCP permissions"; then
        success "Safe MCP operations auto-approved"
        info "Write/dangerous operations will still require approval:"
        info "  • GitHub: create/update/merge operations"
        info "  • Memory: create/delete operations"
        info "  • Puppeteer: click/fill/evaluate operations"
        info "  • Git: commit/push/branch operations"
    fi
fi