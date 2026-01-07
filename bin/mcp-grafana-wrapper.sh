#!/bin/bash
# Wrapper script for mcp-grafana that uses kubectl port-forward to bypass ALB Cognito auth
#
# The PostHog Grafana instance requires Cognito OAuth at the ALB level, which doesn't
# support Bearer token authentication. This script creates a port-forward to access
# Grafana directly within the K8s cluster.
#
# Supports switching between prod-us, prod-eu, and dev regions via ~/.grafana-region file.
# Use `grafana-region us`, `grafana-region eu`, or `grafana-region dev` to switch,
# then restart the MCP server.

set -e

# Region configuration
REGION_FILE="$HOME/.grafana-region"
DEFAULT_REGION="us"

# Read current region (default to us)
if [ -f "$REGION_FILE" ]; then
    CURRENT_REGION=$(cat "$REGION_FILE")
else
    CURRENT_REGION="$DEFAULT_REGION"
fi

# Validate region
if [[ "$CURRENT_REGION" != "us" && "$CURRENT_REGION" != "eu" && "$CURRENT_REGION" != "dev" ]]; then
    echo "Error: Invalid region '$CURRENT_REGION' in $REGION_FILE. Must be 'us', 'eu', or 'dev'." >&2
    exit 1
fi

# Region-specific configuration
case "$CURRENT_REGION" in
    us)
        LOCAL_PORT=13000
        K8S_CONTEXT="arn:aws:eks:us-east-1:854902948032:cluster/posthog-prod"
        KEYCHAIN_SERVICE="grafana-service-account-token-us"
        PID_FILE="/tmp/grafana-port-forward-us.pid"
        ;;
    eu)
        LOCAL_PORT=13001
        K8S_CONTEXT="arn:aws:eks:eu-central-1:730758685644:cluster/posthog-prod-eu"
        KEYCHAIN_SERVICE="grafana-service-account-token-eu"
        PID_FILE="/tmp/grafana-port-forward-eu.pid"
        ;;
    dev)
        LOCAL_PORT=13002
        K8S_CONTEXT="arn:aws:eks:us-east-1:169684386827:cluster/posthog-dev"
        KEYCHAIN_SERVICE="grafana-service-account-token-dev"
        PID_FILE="/tmp/grafana-port-forward-dev.pid"
        ;;
esac

GRAFANA_NAMESPACE="monitoring"
GRAFANA_SERVICE="grafana"

# Get the service account token from keychain
export GRAFANA_SERVICE_ACCOUNT_TOKEN="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)"

if [ -z "$GRAFANA_SERVICE_ACCOUNT_TOKEN" ]; then
    echo "Error: Could not retrieve $KEYCHAIN_SERVICE from keychain" >&2
    echo "Add it with: security add-generic-password -a \"\$USER\" -s \"$KEYCHAIN_SERVICE\" -w \"YOUR_TOKEN\"" >&2
    exit 1
fi

# Check if kubectl is available
if ! command -v kubectl &> /dev/null; then
    echo "Error: kubectl is not installed or not in PATH" >&2
    exit 1
fi

# Function to check if port-forward is already running and healthy
is_port_forward_healthy() {
    # Check if PID file exists and process is running
    if [ -f "$PID_FILE" ]; then
        local pid=$(cat "$PID_FILE")
        if kill -0 "$pid" 2>/dev/null; then
            # Process exists, check if port is actually listening
            if nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
                return 0
            fi
        fi
        # PID file exists but process is dead or port not listening, clean up
        rm -f "$PID_FILE"
    fi
    return 1
}

# Function to start port-forward
start_port_forward() {
    # Check if we can connect to the cluster
    if ! kubectl --context="$K8S_CONTEXT" cluster-info &> /dev/null 2>&1; then
        echo "Error: Cannot connect to K8s cluster ($CURRENT_REGION). Your AWS SSO session may have expired." >&2
        echo "Try running: aws sso login" >&2
        exit 1
    fi

    # Start port-forward in background (not tied to this script's lifecycle)
    nohup kubectl --context="$K8S_CONTEXT" port-forward -n "$GRAFANA_NAMESPACE" "svc/$GRAFANA_SERVICE" "$LOCAL_PORT:80" &> /dev/null &
    local pf_pid=$!
    echo "$pf_pid" > "$PID_FILE"

    # Give port-forward time to establish
    sleep 2

    # Check if port-forward is running
    if ! kill -0 "$pf_pid" 2>/dev/null; then
        echo "Error: Failed to establish port-forward to Grafana ($CURRENT_REGION)" >&2
        rm -f "$PID_FILE"
        exit 1
    fi
}

# Reuse existing port-forward or start a new one
if ! is_port_forward_healthy; then
    start_port_forward
fi

# Set Grafana URL to use the port-forward
export GRAFANA_URL="http://localhost:$LOCAL_PORT"

# Run mcp-grafana (no cleanup trap - let the port-forward persist)
exec /Users/haacked/dev/third-party/mcp-grafana/mcp-grafana "$@"
