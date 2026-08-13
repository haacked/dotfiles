#!/usr/bin/env bash
# ci-quarantine-status.sh - Read a PR's Trunk Test Analytics badge counts.
#
# Trunk's flaky-test quarantining masks a quarantined test's failure so it
# cannot fail a required check. The analytics comment Trunk keeps on each PR
# carries per-commit failed and quarantined counts, which is how a caller
# tells "unquarantined flakes did the evicting" from "quarantining was never
# in play" after a merge-queue eviction - pass the merge PR's number. What a
# reading means for a given eviction stays with the caller; this only parses.
#
# This script is READ-ONLY: it never comments, enqueues, or pushes. The parse
# is a pure function (helpers/quarantine-state.jq); this wrapper only fetches
# the comment. It fails closed: any error reads as readable:false, never as a
# count.
#
# Usage:
#   ci-quarantine-status.sh <pr_number> [<org/repo>]
#
# Output: JSON { readable, failed, quarantined, commit, updated_at, error }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq

QUARANTINE_JQ="${SCRIPT_DIR}/helpers/quarantine-state.jq"

pr_number="${1:?Usage: ci-quarantine-status.sh <pr_number> [<org/repo>]}"
repo_arg="${2:-}"

# Emit a fail-closed reading and exit 0 (callers parse JSON, not exit codes).
emit_unreadable() {
    jq -n --arg reason "$1" '{
        readable: false, failed: null, quarantined: null,
        commit: null, updated_at: null, error: $reason
    }'
    exit 0
}

repo_nwo=$(ci_resolve_repo_nwo "${repo_arg}")
[[ -n "${repo_nwo}" ]] || emit_unreadable "could not resolve owner/repo"

# ── Analytics comment ────────────────────────────────────────────────────────

comments_json=$(ci_fetch_pr_comments "${pr_number}" "${repo_nwo}") \
    || emit_unreadable "could not fetch comments for PR #${pr_number}"
[[ -n "${comments_json}" ]] || comments_json="[]"

# Trunk edits its analytics comment in place, so the most recently updated
# one is the current reading.
analytics=$(echo "${comments_json}" | jq --arg bot "${CI_TRUNK_BOT}" '
    [ .[][]
      | select(.user.login == $bot and .user.type == "Bot")
      | select((.body // "") | contains("<!-- Trunk Test Analytics -->"))
      | {body, updated_at} ]
    | sort_by(.updated_at) | last // {body: null, updated_at: null}' 2> /dev/null) \
    || emit_unreadable "could not parse comments for PR #${pr_number}"

echo "${analytics}" | jq -f "${QUARANTINE_JQ}" | jq '. + {error: null}'
