#!/usr/bin/env bash
# Capture Grafana dashboard screenshots via Playwright and a kubectl port-forward.
#
# Retrieves the Grafana service account token from the macOS Keychain (same pattern
# as mcp-grafana-wrapper.sh), verifies the port-forward is listening, and hands off
# to screenshot.mjs for the actual browser work.
#
# Usage:
#   grafana-screenshot.sh --dashboards uid1,uid2 --output /tmp/shots \
#     [--from now-24h] [--to now] [--region us|eu|dev] \
#     [--width 1400] [--height 900]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
DASHBOARDS=""
OUTPUT_DIR="/tmp/grafana-screenshots"
FROM="now-24h"
TO="now"
REGION="us"
WIDTH=1400
HEIGHT=900

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dashboards) DASHBOARDS="$2"; shift 2 ;;
    --output)     OUTPUT_DIR="$2"; shift 2 ;;
    --from)       FROM="$2"; shift 2 ;;
    --to)         TO="$2"; shift 2 ;;
    --region)     REGION="$2"; shift 2 ;;
    --width)      WIDTH="$2"; shift 2 ;;
    --height)     HEIGHT="$2"; shift 2 ;;
    *)
      echo "Unknown argument: $1" >&2
      exit 1
      ;;
  esac
done

if [[ -z "$DASHBOARDS" ]]; then
  echo "Error: --dashboards is required (comma-separated UIDs)" >&2
  exit 1
fi

# Region to port mapping (matches mcp-grafana-wrapper.sh)
case "$REGION" in
  us)  LOCAL_PORT=13000; KEYCHAIN_SERVICE="grafana-service-account-token-us" ;;
  eu)  LOCAL_PORT=13001; KEYCHAIN_SERVICE="grafana-service-account-token-eu" ;;
  dev) LOCAL_PORT=13002; KEYCHAIN_SERVICE="grafana-service-account-token-dev" ;;
  *)
    echo "Error: Invalid region '$REGION'. Must be 'us', 'eu', or 'dev'." >&2
    exit 1
    ;;
esac

# Retrieve token from macOS Keychain
if [[ "$OSTYPE" == "darwin"* ]]; then
  TOKEN="$(security find-generic-password -a "$USER" -s "$KEYCHAIN_SERVICE" -w 2>/dev/null)" || true
else
  TOKEN="${GRAFANA_SERVICE_ACCOUNT_TOKEN:-}"
fi

if [[ -z "$TOKEN" ]]; then
  echo "Error: Could not retrieve $KEYCHAIN_SERVICE from keychain" >&2
  echo "Add it with: grafana-token $REGION <your-token>" >&2
  exit 1
fi

# Verify the port-forward is listening
if ! nc -z localhost "$LOCAL_PORT" 2>/dev/null; then
  echo "Error: Nothing listening on localhost:$LOCAL_PORT" >&2
  echo "Start the port-forward first (the Grafana MCP server does this automatically," >&2
  echo "or run: kubectl port-forward -n monitoring svc/grafana $LOCAL_PORT:80)" >&2
  exit 1
fi

# Ensure node_modules are installed
if [[ ! -d "$SCRIPT_DIR/node_modules" ]]; then
  echo "Installing dependencies..." >&2
  npm install --prefix "$SCRIPT_DIR" --no-audit --no-fund >&2
fi

mkdir -p "$OUTPUT_DIR"

# Hand off to the Node.js screenshot script
exec node "$SCRIPT_DIR/screenshot.mjs" \
  --token "$TOKEN" \
  --port "$LOCAL_PORT" \
  --dashboards "$DASHBOARDS" \
  --output "$OUTPUT_DIR" \
  --from "$FROM" \
  --to "$TO" \
  --width "$WIDTH" \
  --height "$HEIGHT"
