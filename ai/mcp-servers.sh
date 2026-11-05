#!/bin/sh
# Shared MCP server inventory for AI tooling installers.

# shellcheck disable=SC2034 # Read by the installers that source this file.

# Format: name|transport|description|target
MCP_SERVERS="
posthog-db|stdio|PostHog database connection|$HOME/.local/bin/postgres-mcp --access-mode=restricted
"

# Codex registers these servers for every session. A user-scope Claude
# registration would start them in every Claude session. The Claude agents that
# query Grafana therefore declare them inline in their mcpServers frontmatter.
# The hosted servers authenticate the user through Tailscale and need no token.
CODEX_ONLY_MCP_SERVERS="
grafana|http|Grafana MCP server (US)|https://grafana-mcp-prod-us.hedgehog-kitefin.ts.net/mcp
grafana-eu|http|Grafana MCP server (EU)|https://grafana-mcp-prod-eu.hedgehog-kitefin.ts.net/mcp
grafana-dev|http|Grafana MCP server (dev)|https://grafana-mcp-dev.hedgehog-kitefin.ts.net/mcp
"

server_env_values() {
	case "$1" in
	posthog-db) echo "DATABASE_URI=postgresql://posthog:posthog@localhost:5432/posthog" ;;
	*) echo "" ;;
	esac
}

server_env_args() {
	local env_flag="$1"
	local server_name="$2"
	local env_value
	for env_value in $(server_env_values "$server_name"); do
		printf '%s %s ' "$env_flag" "$env_value"
	done
}

set_server_env() { server_env_args -e "$1"; }
set_codex_server_env() { server_env_args --env "$1"; }

# `claude mcp add` accepts a command that does not exist, which is how a stale path
# sits in the server list unnoticed. Verify the executable before registering it.
stdio_command_available() {
	case "$1" in
	/*) [ -x "$1" ] ;;
	*) command -v "$1" >/dev/null 2>&1 ;;
	esac
}

# Installs a missing stdio command when this inventory knows how, then reports
# whether the command is available.
ensure_stdio_command() { # server_name command
	stdio_command_available "$2" && return 0
	case "$1" in
	posthog-db)
		# postgres-mcp 0.3.0 needs Python 3.12 and mcp below 2. Its pglast dependency
		# has no wheel for newer Pythons and fails to build from source against the
		# current macOS SDK. It imports mcp.server.fastmcp, which mcp 2 removed. It
		# declares no upper bound on mcp. The constraint applies in the same pip
		# resolution. A failed install therefore leaves no venv with mcp 2.
		command -v pipx >/dev/null 2>&1 || return 1
		local constraints
		constraints=$(mktemp) || return 1
		echo 'mcp<2' >"$constraints"
		pipx install --python python3.12 --pip-args="--constraint=$constraints" 'postgres-mcp==0.3.0'
		rm -f "$constraints"
		;;
	*) return 1 ;;
	esac
	stdio_command_available "$2"
}
