#!/bin/bash
# Wrapper script for mcp-grafana that uses kubectl port-forward to bypass ALB Cognito auth
#
# The PostHog Grafana instance requires Cognito OAuth at the ALB level, which doesn't
# support Bearer token authentication. This script creates a port-forward to access
# Grafana directly within the K8s cluster.

set -e

# Configuration
LOCAL_PORT=13000  # Using a high port to avoid conflicts
GRAFANA_NAMESPACE="monitoring"
GRAFANA_SERVICE="grafana"
K8S_CONTEXT="arn:aws:eks:us-east-1:854902948032:cluster/posthog-prod"
PID_FILE="/tmp/grafana-port-forward.pid"

# Get the service account token from keychain
export GRAFANA_SERVICE_ACCOUNT_TOKEN="$(security find-generic-password -a "$USER" -s "grafana-service-account-token" -w 2>/dev/null)"

if [ -z "$GRAFANA_SERVICE_ACCOUNT_TOKEN" ]; then
    echo "Error: Could not retrieve grafana-service-account-token from keychain" >&2
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
        echo "Error: Cannot connect to K8s cluster. Your AWS SSO session may have expired." >&2
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
        echo "Error: Failed to establish port-forward to Grafana" >&2
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
