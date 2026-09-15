#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DESTINATION="$REPO_ROOT/ai/skills/wait-for-pr-reviews/scripts"

if [[ $# -gt 1 || ($# -eq 1 && "$1" != "--check") ]]; then
  echo "Usage: $0 [--check]" >&2
  exit 1
fi

mode="${1:-sync}"
helpers=(detect-pr.sh git-pr lib/logging.sh lib/github.sh)
failures=0
for helper in "${helpers[@]}"; do
  source_file="$REPO_ROOT/bin/$helper"
  bundled_file="$DESTINATION/$helper"
  if [[ "$mode" == "--check" ]]; then
    if ! cmp -s "$source_file" "$bundled_file" ||
      [[ -x "$source_file" && ! -x "$bundled_file" ]] ||
      [[ ! -x "$source_file" && -x "$bundled_file" ]]; then
      echo "Missing or stale bundled helper: $helper. Run ai/bin/sync-pr-review-helpers.sh." >&2
      failures=$((failures + 1))
    fi
  else
    mkdir -p "$(dirname "$bundled_file")"
    cp -p "$source_file" "$bundled_file"
  fi
done

[[ "$failures" -eq 0 ]]
