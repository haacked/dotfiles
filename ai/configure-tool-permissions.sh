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
      "mcp__posthog-db__*",
      "mcp__memory__read_graph",
      "mcp__memory__search_nodes",
      "mcp__memory__open_nodes",
      "mcp__grafana__list_datasources",
      "mcp__grafana__list_loki_label_names",
      "mcp__grafana__list_loki_label_values",
      "mcp__grafana__query_loki_logs",
      "mcp__grafana__query_prometheus",
      "WebFetch(domain:*)",
      "WebSearch",
      "Fetch(*)",
      "Read(/tmp/**)",
      "Read(~/.claude/**)",
      "Read(//Users/haacked/dev/**)",
      "Bash(* > /tmp/*)",
      "Bash(DJANGO_SETTINGS_MODULE=:*)",
      "Bash([ -d :*)",
      "Bash([ -e :*)",
      "Bash([ -f :*)",
      "Bash(test -d :*)",
      "Bash(test -e :*)",
      "Bash(test -f :*)",
      "Bash(ai/bin/*:*)",
      "Bash(./ai/bin/*:*)",
      "Bash(bin/fmt:*)",
      "Bash(./bin/fmt:*)",
      "Bash(bin/ruff.sh:*)",
      "Bash(./bin/ruff.sh:*)",
      "Bash(~/.claude/bin/*:*)",
      "Bash(~/.claude/skills/*:*)",
      "Bash(awk:*)",
      "Bash(bash:*)",
      "Bash(brew info:*)",
      "Bash(brew list:*)",
      "Bash(cargo :*)",
      "Bash(cat:*)",
      "Bash(cd :* && cargo:*)",
      "Bash(chmod:*)",
      "Bash(claude:*)",
      "Bash(curl:*)",
      "Bash(docker compose:*)",
      "Bash(docker network:*)",
      "Bash(echo:*)",
      "Bash(find:*)",
      "Bash(flox activate:*)",
      "Bash(gawk:*)",
      "Bash(gh api:*)",
      "Bash(gh auth status:*)",
      "Bash(gh issue list:*)",
      "Bash(gh issue view:*)",
      "Bash(gh pr checks:*)",
      "Bash(gh pr checkout:*)",
      "Bash(gh pr create:*)",
      "Bash(gh pr diff:*)",
      "Bash(gh pr list:*)",
      "Bash(gh pr status:*)",
      "Bash(gh pr view:*)",
      "Bash(gh release list:*)",
      "Bash(gh release view:*)",
      "Bash(gh repo clone:*)",
      "Bash(gh repo fork:*)",
      "Bash(gh repo list:*)",
      "Bash(gh repo view:*)",
      "Bash(gh run list:*)",
      "Bash(gh run view:*)",
      "Bash(gh run watch:*)",
      "Bash(gh search:*)",
      "Bash(gh status:*)",
      "Bash(gh workflow list:*)",
      "Bash(gh workflow view:*)",
      "Bash(git --version:*)",
      "Bash(git add:*)",
      "Bash(git blame:*)",
      "Bash(git branch:*)",
      "Bash(git check-ignore:*)",
      "Bash(git checkout:*)",
      "Bash(git cherry-pick:*)",
      "Bash(git commit:*)",
      "Bash(git config:*)",
      "Bash(git diff:*)",
      "Bash(git fetch:*)",
      "Bash(git log:*)",
      "Bash(git merge:*)",
      "Bash(git pull:*)",
      "Bash(git rebase:*)",
      "Bash(git reflog:*)",
      "Bash(git remote:*)",
      "Bash(git reset:*)",
      "Bash(git rev-list:*)",
      "Bash(git rev-parse:*)",
      "Bash(git shortlog:*)",
      "Bash(git show:*)",
      "Bash(git stash:*)",
      "Bash(git switch:*)",
      "Bash(git tag:*)",
      "Bash(git worktree:*)",
      "Bash(grep:*)",
      "Bash(head:*)",
      "Bash(ln:*)",
      "Bash(ls:*)",
      "Bash(markdownlint:*)",
      "Bash(mypy --version && mypy -p posthog | mypy-baseline filter:*)",
      "Bash(mypy:*)",
      "Bash(node:*)",
      "Bash(npm:*)",
      "Bash(npx:*)",
      "Bash(openssl:*)",
      "Bash(osascript:*)",
      "Bash(pbcopy:*)",
      "Bash(pip:*)",
      "Bash(pip3:*)",
      "Bash(pnpm:*)",
      "Bash(pyenv:*)",
      "Bash(pytest:*)",
      "Bash(python -c:*)",
      "Bash(python -m mypy:*)",
      "Bash(python -m pytest:*)",
      "Bash(python3:*)",
      "Bash(python:*)",
      "Bash(redis-cli:*)",
      "Bash(ruff:*)",
      "Bash(sed:*)",
      "Bash(snob:*)",
      "Bash(sort:*)",
      "Bash(source:*)",
      "Bash(ssh:*)",
      "Bash(swift:*)",
      "Bash(tail:*)",
      "Bash(tmux:*)",
      "Bash(wc:*)",
      "Bash(which:*)",
      "Bash(xargs:*)",
      "Bash(xattr:*)",
      "Bash(zsh:*)"
    ]
  }
}
EOF
)

# Check if key permissions are configured
if command -v jq > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "mcp__posthog-db__*")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(cargo :*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(git log:*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(gh pr list:*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(npx:*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(~/.claude/skills/*:*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Bash(ruff:*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Fetch(*)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Read(/tmp/**)")' "$SETTINGS_FILE" > /dev/null 2>&1 && \
   jq -e '.permissions.allow[] | select(. == "Read(//Users/haacked/dev/**)")' "$SETTINGS_FILE" > /dev/null 2>&1; then
    success "Tool permissions already configured"
else
    # Merge permissions configuration using helper function
    if merge_json_settings "$SETTINGS_FILE" "$PERMISSIONS_CONFIG" "MCP permissions"; then
        success "Safe tool operations auto-approved"
        info "Write/dangerous operations will still require approval:"
        info "  - GitHub: create/update/merge operations"
        info "  - Memory: create/delete operations"
        info "  - Git: push operations (add/commit/read operations are auto-approved)"
        info "  - GitHub CLI: create/merge operations (read operations are auto-approved)"
    fi
fi
