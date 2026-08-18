#!/usr/bin/env bash
# Print raw-area sources not yet named by an "ingest |" entry in the operations
# log, oldest first (by mtime).
#
# Usage: vault-next-source.sh [count|all]
#
# Prints one vault-relative path per line (default: 1). The backlog count goes
# to stderr so stdout stays machine-consumable. A source counts as processed
# when its backtick-wrapped vault-relative path (extension included) appears
# inside an "ingest |" entry — the exact token those entries write, so one
# source's path can't substring-match another's (Granola exports produce
# prefix-sibling filenames). Naming a path in any other entry type does not
# mark it processed.

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

# The raw layer is one directory, per the schema in CLAUDE.md.
# BSD stat: this setup is macOS-only.
raw_list=$(find raw -type f -name '*.md' -print0 2>/dev/null | xargs -0 stat -f '%m|%N' 2>/dev/null | sort -n | cut -d'|' -f2- || true)

if [[ -z "$raw_list" ]]; then
    echo "No raw sources found under $VAULT" >&2
    exit 0
fi

# Only "ingest |" entries mark a source processed. Any other entry — a lint or
# note that happens to name a raw path in backticks — would otherwise hide that
# source from the backlog permanently. An entry runs from its "## [date] op |"
# heading to the next "## " heading; text before the first heading counts for
# nothing.
ingest_entries=$(awk '
    /^## / { in_ingest = ($0 ~ /^## \[[^]]*\][[:space:]]*ingest[[:space:]]*\|/) }
    in_ingest
' "$LOG_FILE")

# One grep fork per raw file (~1s at 260 files, fork-bound not size-bound);
# an awk lookup-set join only pays off once the backlog reaches the thousands.
# Entries dated before the 2026-08-18 raw/ move name paths without the prefix,
# and the schema requires tooling to accept both forms; matching only the
# current form would re-ingest every source processed before the move.
pending=$(printf '%s\n' "$raw_list" | while IFS= read -r f; do
    if grep -qF "\`${f}\`" <<< "$ingest_entries" ||
        grep -qF "\`${f#raw/}\`" <<< "$ingest_entries"; then
        continue
    fi
    printf '%s\n' "$f"
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
