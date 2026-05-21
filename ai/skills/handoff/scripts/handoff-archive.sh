#!/usr/bin/env bash
# Move a handoff doc into the sibling handoff-archive/ directory.
# Usage: handoff-archive.sh <path-to-handoff.md>
# Output: prints the archived path on success, or nothing if source missing.

set -euo pipefail

if [[ $# -lt 1 ]]; then
    echo "Usage: handoff-archive.sh <path-to-handoff.md>" >&2
    exit 1
fi

src="$1"

if [[ ! -f "$src" ]]; then
    exit 0
fi

src_dir=$(dirname "$src")
src_base=$(basename "$src" .md)
ts=$(date '+%Y%m%d-%H%M%S')
archive_dir="${src_dir}/handoff-archive"

mkdir -p "$archive_dir"

# Two archives within the same second would collide on the timestamp.
# Disambiguate with a numeric suffix so the prior archive is never overwritten.
target="${archive_dir}/${src_base}-${ts}.md"
suffix=1
while [[ -e "$target" ]]; do
    target="${archive_dir}/${src_base}-${ts}-${suffix}.md"
    suffix=$((suffix + 1))
done

mv -n "$src" "$target" || { echo "archive target already exists: $target" >&2; exit 1; }
echo "$target"
