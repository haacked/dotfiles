#!/bin/sh
# Shared MCP server inventory for AI tooling installers.

# shellcheck disable=SC2034 # Read by the installers that source this file.

# The wrapper lives in the PostHog checkout, so the Grafana servers are skipped on
# machines without it. GRAFANA_MCP_PATH is injected because the wrapper shells out to
# mcp-grafana on the Go path, which the server does not inherit.
GRAFANA_MCP_WRAPPER="$HOME/dev/posthog/posthog/tools/infra-scripts/mcp/mcp-grafana-wrapper.sh"
GRAFANA_MCP_PATH="/usr/local/bin:/usr/bin:/bin:$HOME/go/bin"

# Format: name|transport|description|target
MCP_SERVERS="
posthog-db|stdio|PostHog database connection|$HOME/.local/bin/postgres-mcp --access-mode=restricted
grafana|stdio|Grafana MCP server (US)|$GRAFANA_MCP_WRAPPER
grafana-eu|stdio|Grafana MCP server (EU)|$GRAFANA_MCP_WRAPPER
grafana-dev|stdio|Grafana MCP server (dev)|$GRAFANA_MCP_WRAPPER
ops|http|PostHog Ops MCP server|https://ops.posthog.dev/api/mcp
"

server_env_values() {
	case "$1" in
	posthog-db) echo "DATABASE_URI=postgresql://posthog:posthog@localhost:5432/posthog" ;;
	grafana) echo "PATH=$GRAFANA_MCP_PATH GRAFANA_REGION=us" ;;
	grafana-eu) echo "PATH=$GRAFANA_MCP_PATH GRAFANA_REGION=eu" ;;
	grafana-dev) echo "PATH=$GRAFANA_MCP_PATH GRAFANA_REGION=dev" ;;
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
