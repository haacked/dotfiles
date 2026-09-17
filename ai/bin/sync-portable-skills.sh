#!/usr/bin/env bash
# Copy every portable skill's helpers into its scripts/ folder, or verify that
# the copies are current.
#
# Usage: sync-portable-skills.sh [--check]
#
# --check names each missing, stale, or wrongly permissioned copy and exits
# non-zero. CI runs it so a helper edited under bin/ cannot reach main while a
# skill still ships the old text. ai/helpers/portable-skills.sh holds the table.
#
# Both modes walk the table, never the skill folder, so a copy whose row was renamed
# or deleted stays behind and is not reported. Delete such a copy by hand.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
# shellcheck source=ai/helpers/portable-skills.sh
source "$SCRIPT_DIR/../helpers/portable-skills.sh"

if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--check") ]]; then
  echo "Usage: $(basename "$0") [--check]" >&2
  exit 1
fi

mode="${1:-}"
failures=0

# Every source is checked before anything is written. cmp reports a missing source
# the same way it reports a changed one, so without this pass a deleted source reads
# as a stale copy, and the sync it tells you to run dies partway with a bare cp error.
while read -r skill; do
  while read -r source _; do
    if [[ ! -f "$REPO_ROOT/$source" ]]; then
      echo "Missing helper source: $source, which ai/helpers/portable-skills.sh names for $skill." >&2
      failures=$((failures + 1))
    fi
  done < <(portable_skill_helpers "$skill")
done < <(portable_skill_names)

if [[ "$failures" -gt 0 ]]; then
  exit 1
fi

while read -r skill; do
  while read -r source destination; do
    bundled="ai/skills/$skill/scripts/$destination"
    source_file="$REPO_ROOT/$source"
    bundled_file="$REPO_ROOT/$bundled"
    if [[ "$mode" == "--check" ]]; then
      if ! cmp -s "$source_file" "$bundled_file" ||
        [[ -x "$source_file" && ! -x "$bundled_file" ]] ||
        [[ ! -x "$source_file" && -x "$bundled_file" ]]; then
        echo "Missing or stale copy: $bundled. Edit $source instead, then run ai/bin/sync-portable-skills.sh." >&2
        failures=$((failures + 1))
      fi
    else
      mkdir -p "$(dirname "$bundled_file")"
      cp -p "$source_file" "$bundled_file"
    fi
  done < <(portable_skill_helpers "$skill")
done < <(portable_skill_names)

[[ "$failures" -eq 0 ]]
