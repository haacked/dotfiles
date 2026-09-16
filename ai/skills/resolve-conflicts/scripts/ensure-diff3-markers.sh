#!/bin/bash
# Rewrite conflicted working-tree files so their markers carry a base section.
#
# Usage: ensure-diff3-markers.sh
#
# Output format (tab-separated, one per line):
#   rewrote\t<file_path>
#
# Git writes the "||||||| " base section only when merge.conflictStyle is
# diff3 or zdiff3. This script re-creates the markers in diff3 style when the
# host leaves that setting unset.

set -euo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || {
    echo "Error: not in a git repository" >&2
    exit 1
}

style=$(git config --default '' --get merge.conflictStyle)
case "$style" in
    diff3|zdiff3) exit 0 ;;
esac

while IFS= read -r -d '' file; do
    # A conflicted path with no "<<<<<<<" holds a binary or delete/modify
    # conflict, or a resolution that rerere replayed. A rewrite destroys
    # that resolution.
    if ! grep -qI '^<<<<<<<' "$file" 2>/dev/null; then
        continue
    fi
    if grep -qI '^|||||||' "$file" 2>/dev/null; then
        continue
    fi

    if ! git checkout --conflict=diff3 -- "$file" 2>/dev/null; then
        echo "Warning: could not rewrite conflict markers in $file" >&2
        continue
    fi

    # A merge driver named by a gitattributes "merge=" rule re-runs here.
    # Its output wins, so the re-checkout does not always add a base section.
    if grep -qI '^|||||||' "$file" 2>/dev/null; then
        printf "rewrote\t%s\n" "$file"
    fi
done < <(git diff --name-only --diff-filter=U -z 2>/dev/null)
