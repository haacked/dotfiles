#!/usr/bin/env bash
# detect-pr.sh - Detect PR from a URL, number, or current branch
#
# Usage: detect-pr.sh [--json] [<pr-url>|<pr-number>]
#
# Output formats:
#   Default (TSV): <owner>\t<repo_name>\t<repo>\t<pr_number>
#   --json:        {"pr_number":N,"org":"…","repo":"…","head_branch":"…","head_sha":"…","error":null}
#
# Exit codes:
#   TSV mode:  0 on success, 1 on error
#   JSON mode: always 0 (errors reported in the "error" field)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=lib/github.sh
source "${SCRIPT_DIR}/lib/github.sh"

# ── Parse flags ──────────────────────────────────────────────────────────────

format="tsv"
pr_arg=""
for arg in "$@"; do
  case "$arg" in
    --json) format="json" ;;
    *) pr_arg="$arg" ;;
  esac
done

# ── TSV mode ─────────────────────────────────────────────────────────────────

if [[ "$format" == "tsv" ]]; then
  resolve_pr_target "$pr_arg"
  printf '%s\t%s\t%s\t%s\n' "$OWNER" "$REPO_NAME" "$REPO" "$PR_NUMBER"
  exit 0
fi

# ── JSON mode ────────────────────────────────────────────────────────────────

# Require jq for JSON output
if ! command -v jq > /dev/null 2>&1; then
  printf '{"error":"Required command not found: jq"}\n'
  exit 0
fi

json_error() {
  jq -n --arg msg "$1" '{"error": $msg}'
}

# Capture stderr from resolve_pr_target (log_error writes there)
err_file=$(mktemp)
trap 'rm -f "$err_file"' EXIT

if ! resolve_pr_target "$pr_arg" 2>"$err_file"; then
  # Strip ANSI color codes and [ERROR] prefix, join lines into one message
  err=$(sed $'s/\x1b\\[[0-9;]*m//g; s/^\\[ERROR\\] //' "$err_file" | paste -sd ' ' -)
  json_error "${err:-Failed to resolve PR target}"
  exit 0
fi

# Fetch head branch and SHA
pr_json=$(gh pr view "$PR_NUMBER" --repo "$REPO" --json headRefName,headRefOid 2>/dev/null) || {
  json_error "Could not fetch PR #${PR_NUMBER} from ${REPO}"
  exit 0
}

echo "$pr_json" | jq \
  --argjson pr_number "$PR_NUMBER" \
  --arg org "${OWNER,,}" \
  --arg repo "${REPO_NAME,,}" \
  '{
    pr_number: $pr_number,
    org: $org,
    repo: $repo,
    head_branch: .headRefName,
    head_sha: .headRefOid,
    error: null
  }'
