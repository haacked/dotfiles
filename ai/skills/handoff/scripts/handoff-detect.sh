#!/usr/bin/env bash
# SessionStart hook: surface the existence of a handoff doc for the current cwd
# without reading or loading its contents. Silent when there is nothing to surface.
#
# This script is best-effort: any error must not block session start.

set -uo pipefail

path_helper="${HOME}/.claude/skills/handoff/scripts/handoff-path.sh"

if [[ ! -x "$path_helper" ]]; then
    exit 0
fi

result=$("$path_helper" 2>/dev/null) || exit 0

status=$(printf '%s' "$result" | cut -f1)
path=$(printf '%s'   "$result" | cut -f2)
scope=$(printf '%s'  "$result" | cut -f3)

if [[ "$status" != "existing" ]]; then
    exit 0
fi

ts_line=$(grep -m1 '^timestamp:' "$path" 2>/dev/null | sed 's/^timestamp:[[:space:]]*//' || true)
goal_line=$(grep -m1 '^# Handoff:' "$path" 2>/dev/null | sed 's/^# Handoff:[[:space:]]*//' || true)

cat <<EOF
[handoff] A handoff doc exists for this work (${scope}):
  path:      ${path}
  written:   ${ts_line:-unknown}
  goal:      ${goal_line:-unknown}

Run \`/handoff resume\` to load it (will offer to archive after reading), or \`/handoff show\` to print it without acting.
EOF
