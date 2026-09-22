#!/usr/bin/env bash
# Copy every portable skill's helpers and vendored skills into its folder, or verify
# that the copies are current.
#
# Usage: sync-portable-skills.sh [--check]
#
# --check names each missing, stale, or wrongly permissioned copy and exits
# non-zero. CI runs it so a helper edited under bin/ cannot reach main while a
# skill still ships the old text. ai/helpers/portable-skills.sh holds the table.
#
# A third pass walks each skill folder and reports a file that neither table in
# ai/helpers/portable-skills.sh names, which is what a copy whose row was renamed or
# deleted looks like. Write mode deletes it. A new hand-maintained file has to be
# added to PORTABLE_SKILL_OWN_FILES before either mode accepts it.
#
# A fourth pass walks the source folder behind each references/<skill>/ copy and reports
# a file no row names. The other passes all start from the table, so without this one a
# file added to a vendored skill reaches no copy while CI stays green. The sandbox then
# follows a link into a file that never travelled. Neither mode writes the copy, because
# only a human decides whether a new source file belongs in the bundle.
#
# That pass finds the source folder by mirroring the destination, so it checks the mirror
# first. A row that breaks it would otherwise send the walk to a directory that is not
# there, where it reads nothing and reports nothing.

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
    bundled="ai/skills/$skill/$destination"
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

while read -r skill; do
  skill_dir="$REPO_ROOT/ai/skills/$skill"
  [[ -d "$skill_dir" ]] || continue
  declared=$({
    portable_skill_helpers "$skill" | awk '{print $2}'
    portable_skill_own_files "$skill"
  } | sort -u)
  while read -r found; do
    [[ -n "$found" ]] || continue
    if ! grep -qxF "$found" <<<"$declared"; then
      orphan="ai/skills/$skill/$found"
      if [[ "$mode" == "--check" ]]; then
        echo "Undeclared file: $orphan. Add it to PORTABLE_SKILL_OWN_FILES, or run ai/bin/sync-portable-skills.sh to delete it." >&2
        failures=$((failures + 1))
      else
        rm "$REPO_ROOT/$orphan"
        echo "Deleted undeclared file: $orphan." >&2
      fi
    fi
  done < <(cd "$skill_dir" && find . -type f | sed 's|^\./||' | sort)
done < <(portable_skill_names)

# A source skill's own tests never travel. __pycache__ is a build artifact the repo
# ignores. Neither counts as a file the bundle is missing.
while read -r skill; do
  sources=$(portable_skill_helpers "$skill" | awk '{print $1}')
  roots=
  while read -r source destination; do
    case "$destination" in
    references/*)
      mirrored="ai/skills/${destination#references/}"
      if [[ "$source" != "$mirrored" ]]; then
        echo "Broken mirror: $destination must come from $mirrored, not $source. A references/<skill>/ copy mirrors ai/skills/<skill>/." >&2
        failures=$((failures + 1))
        continue
      fi
      vendored="${destination#references/}"
      roots+="${vendored%%/*}"$'\n'
      ;;
    esac
  done < <(portable_skill_helpers "$skill")

  while read -r vendored; do
    [[ -n "$vendored" ]] || continue
    source_root="ai/skills/$vendored"
    while read -r found; do
      [[ -n "$found" ]] || continue
      if ! grep -qxF "$source_root/$found" <<<"$sources"; then
        echo "Unvendored source file: $source_root/$found. Add it to PORTABLE_SKILL_TABLE for $skill, so the bundle keeps up with the skill it copies." >&2
        failures=$((failures + 1))
      fi
    done < <(cd "$REPO_ROOT/$source_root" &&
      find . -type f -not -path './scripts/tests/*' -not -path '*/__pycache__/*' | sed 's|^\./||' | sort)
  done < <(sort -u <<<"$roots")
done < <(portable_skill_names)

[[ "$failures" -eq 0 ]]
