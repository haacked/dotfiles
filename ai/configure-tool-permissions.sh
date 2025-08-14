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
      "Bash(mypy .)",
      "Bash(mypy --version && mypy -p posthog | mypy-baseline filter*)",
      "Bash(python -m mypy:*)",
      "Bash(pytest:*)",
      "Bash(python -m pytest:*)",
      "Bash(./bin/fmt:*)",
      "Bash(bin/fmt:*)",
      "Bash(DJANGO_SETTINGS_MODULE=* python -m pytest:*)",
      "Bash(DJANGO_SETTINGS_MODULE=* mypy:*)",
      "Bash(find:*)",
      "Bash(grep:*)",
      "Bash(ruff check:*)",
      "Bash(git log*)",
      "Bash(git status*)",
      "Bash(git diff*)",
      "Bash(git show*)",
      "Bash(git branch*)",
      "Bash(git checkout*)",
      "Bash(git switch*)",
      "Bash(git fetch*)",
      "Bash(git pull*)",
      "Bash(git merge*)",
      "Bash(git rebase*)",
      "Bash(git stash*)",
      "Bash(git worktree*)",
      "Bash(git remote*)",
      "Bash(git tag*)",
      "Bash(git blame*)",
      "Bash(git shortlog*)",
      "Bash(git reflog*)",
      "Bash(gh pr list*)",
      "Bash(gh pr view*)",
      "Bash(gh pr diff*)",
      "Bash(gh pr status*)",
      "Bash(gh pr checks*)",
      "Bash(gh issue list*)",
      "Bash(gh issue view*)",
      "Bash(gh repo view*)",
      "Bash(gh repo list*)",
      "Bash(gh repo clone*)",
      "Bash(gh repo fork*)",
      "Bash(gh status*)",
      "Bash(gh auth status*)",
      "Bash(gh api*)",
      "Bash(gh search*)",
      "Bash(gh run list*)",
      "Bash(gh run view*)",
      "Bash(gh run watch*)",
      "Bash(gh workflow list*)",
      "Bash(gh workflow view*)"
    ]
  }
}
EOF
)

# Check if all permissions are configured by looking for MCP, git, and gh tools
if command -v jq > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "mcp__github__get_file_contents")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(git log*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(gh pr list*)")' "$SETTINGS_FILE" > /dev/null 2>&1; then
    success "Tool permissions already configured"
else
    # Merge permissions configuration using helper function
    if merge_json_settings "$SETTINGS_FILE" "$PERMISSIONS_CONFIG" "MCP permissions"; then
        success "Safe tool operations auto-approved"
        info "Write/dangerous operations will still require approval:"
        info "  • GitHub: create/update/merge operations"
        info "  • Memory: create/delete operations"
        info "  • Puppeteer: click/fill/evaluate operations"
        info "  • Git: commit/push operations (read operations are auto-approved)"
        info "  • GitHub CLI: create/merge operations (read operations are auto-approved)"
    fi
fi