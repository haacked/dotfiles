#!/usr/bin/env bash
# SessionStart hook: surface open follow-up items for the current repo without
# loading their full context. Silent when there is nothing to surface.
#
# This script is best-effort: any error must not block session start.

set -uo pipefail

MAX_SHOWN=3
STALE_DAYS=14

open_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)/followup-open.sh"
[[ -x "$open_helper" ]] || exit 0

repo_context="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)/../../../helpers/repo-context.sh"
[[ -f "$repo_context" ]] || exit 0
# shellcheck source=/dev/null
source "$repo_context"

# Only surface inside a git repo with a parseable GitHub origin.
derive_org_repo || exit 0
repo="${REPO_ORG}/${REPO_REPO}"

open_lines=$("$open_helper" 2>/dev/null) || exit 0
[[ -n "$open_lines" ]] || exit 0

here=$("$open_helper" "$repo" 2>/dev/null) || true
total=$(grep -c . <<< "$open_lines" || true)

if [[ -z "$here" ]]; then
    [[ "$total" -gt 0 ]] && echo "[followup] ${total} open follow-up(s) in other repos — /followup list"
    exit 0
fi

here_count=$(grep -c . <<< "$here" || true)
other=$((total - here_count))

echo "[followup] Open follow-ups for ${repo}:"
printf '%s\n' "$here" | head -n "$MAX_SHOWN" | sed 's/^- \[ \] /  • /'

summary=""
[[ "$here_count" -gt "$MAX_SHOWN" ]] && summary="+$((here_count - MAX_SHOWN)) more here"
[[ "$other" -gt 0 ]] && summary="${summary:+${summary} · }${other} open in other repos"
[[ -n "$summary" ]] && echo "  (${summary} — /followup list)"

# Staleness nudge: scan every line for the minimum date rather than trusting
# file order, so a reordered Open section can't produce a silently wrong age.
oldest_date=$(printf '%s\n' "$here" | sed -nE 's/^- \[ \] ([0-9]{4}-[0-9]{2}-[0-9]{2}).*/\1/p' | sort | head -n 1)
if [[ "$oldest_date" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]]; then
    oldest_epoch=$(date -j -f %Y-%m-%d "$oldest_date" +%s 2>/dev/null || echo "")
    if [[ -n "$oldest_epoch" ]]; then
        age_days=$(( ($(date +%s) - oldest_epoch) / 86400 ))
        if [[ "$age_days" -gt "$STALE_DAYS" ]]; then
            echo "  ⚠ oldest open follow-up here is ${age_days}d old — consider /followup review"
        fi
    fi
fi

exit 0
