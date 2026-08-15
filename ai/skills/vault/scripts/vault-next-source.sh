#!/usr/bin/env bash
# Print raw-area sources not yet named by an "ingest |" entry in the operations
# log, oldest first (by mtime).
#
# Usage: vault-next-source.sh [count|all]
#
# Prints one vault-relative path per line (default: 1). The backlog count goes
# to stderr so stdout stays machine-consumable. A source counts as processed
# when its extensionless vault-relative path appears anywhere in log.md.

set -euo pipefail

VAULT="${VAULT:-$HOME/dev/haacked/notes/PostHog}"
LOG_FILE="$VAULT/log.md"
count="${1:-1}"

if [[ ! -f "$LOG_FILE" ]]; then
    echo "Error: $LOG_FILE not found" >&2
    exit 1
fi

if ! [[ "$count" == "all" || "$count" =~ ^[0-9]+$ ]]; then
    echo "Error: count must be a number or 'all'" >&2
    exit 1
fi

cd "$VAULT"

# Raw areas per the schema in CLAUDE.md; year dirs (Granola exports) match 2###.
# Keep in sync with the raw-area case pattern in vault-lint-links.sh.
raw_list=$(find standup ops-reports daily support 2[0-9][0-9][0-9] -type f -name '*.md' -print0 2>/dev/null | xargs -0 stat -f '%m|%N' 2>/dev/null | sort -n | cut -d'|' -f2- || true)

if [[ -z "$raw_list" ]]; then
    echo "No raw sources found under $VAULT" >&2
    exit 0
fi

# One grep fork per raw file (~1s at 260 files, fork-bound not size-bound);
# an awk lookup-set join only pays off once the backlog reaches the thousands.
pending=$(printf '%s\n' "$raw_list" | while IFS= read -r f; do
    grep -qF "${f%.md}" "$LOG_FILE" || printf '%s\n' "$f"
done)

if [[ -z "$pending" ]]; then
    echo "Backlog empty: every raw source appears in an ingest entry." >&2
    exit 0
fi

total=$(printf '%s\n' "$pending" | grep -c . || true)

if [[ "$count" == "all" ]]; then
    printf '%s\n' "$pending"
else
    printf '%s\n' "$pending" | head -n "$count"
fi
echo "(backlog: ${total} unprocessed raw sources)" >&2
