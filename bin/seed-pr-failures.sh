#!/usr/bin/env bash
# seed-pr-failures.sh - Rebuild the persistent failure ledger from session
# history.
#
# Walks every session-YYYY-MM-DD.json file in $STATE_DIR in chronological
# order. For each PR, tracks a consecutive-failure streak: failures increment
# the counter, a successful review resets it. Writes the resulting ledger to
# $STATE_DIR/pr-failures.json (replacing any existing file).
#
# Usage:
#   seed-pr-failures.sh [--dry-run]
#
# Use this once after upgrading run-pr-reviews.sh to bring the ledger in line
# with what already happened, or any time you want to rebuild from scratch.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/fs.sh"

STATE_DIR="${RUN_PR_REVIEWS_STATE_DIR:-${HOME}/.local/state/review-all-prs}"
FAILURES_FILE="${STATE_DIR}/pr-failures.json"
DRY_RUN=false

usage() {
  cat <<EOF
Usage: $(basename "$0") [--dry-run]

Rebuild $FAILURES_FILE from existing session-*.json files in $STATE_DIR.

Options:
  --dry-run   Print the resulting ledger to stdout without writing.
  -h, --help  Show this help message.
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case $1 in
    --dry-run) DRY_RUN=true; shift ;;
    -h|--help) usage ;;
    *) log_error "Unknown option: $1"; usage ;;
  esac
done

if [[ ! -d "$STATE_DIR" ]]; then
  log_error "State directory not found: $STATE_DIR"
  exit 1
fi

# Find session files sorted by name; the YYYY-MM-DD format makes lexical
# order match chronological order.
session_files=()
while IFS= read -r f; do
  session_files+=("$f")
done < <(find "$STATE_DIR" -maxdepth 1 -name 'session-*.json' -print | sort)

if [[ ${#session_files[@]} -eq 0 ]]; then
  log_warn "No session files found; nothing to seed."
  exit 0
fi

log_info "Found ${#session_files[@]} session file(s) in $STATE_DIR"

# Replay sessions chronologically: a successful review clears the streak,
# every failure increments it. End-of-day UTC is fine for the cool-down
# bucket since session JSON has no per-event timestamps.
ledger='{"version": 1, "prs": {}}'
for f in "${session_files[@]}"; do
  base=$(basename "$f" .json)
  date_part="${base#session-}"
  ts="${date_part}T23:59:59Z"

  session=$(cat "$f")
  ledger=$(jq -n \
    --argjson ledger "$ledger" \
    --argjson session "$session" \
    --arg ts "$ts" \
    '
      ($session.reviewed // [])
        | map(if type == "object" then .url else . end)
        | reduce .[] as $url ($ledger; del(.prs[$url])) as $after_success
      | ($session.failed // [])
        | reduce .[] as $f ($after_success;
            .prs[$f.url] = {
              failures: ((.prs[$f.url].failures // 0) + 1),
              first_failure: (.prs[$f.url].first_failure // $ts),
              last_failure: $ts,
              last_reason: ($f.reason // "unknown")
            })
    ')
done

entry_count=$(echo "$ledger" | jq '.prs | length')
log_info "Resulting ledger has ${entry_count} PR entry/entries"

if [[ "$entry_count" -gt 0 ]]; then
  echo ""
  echo "$ledger" | jq -r '.prs | to_entries[] |
    "  \(.value.failures)× \(.key) (last: \(.value.last_reason) on \(.value.last_failure[0:10]))"'
  echo ""
fi

if [[ "$DRY_RUN" == "true" ]]; then
  log_info "Dry run; not writing."
  echo "$ledger" | jq .
  exit 0
fi

echo "$ledger" | jq . | atomic_write "$FAILURES_FILE"
log_success "Wrote $FAILURES_FILE"
