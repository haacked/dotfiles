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
# host sets neither.

set -euo pipefail

toplevel=$(git rev-parse --show-toplevel 2>/dev/null) || {
    echo "Error: not in a git repository" >&2
    exit 1
}

# git diff reports paths from the top of the working tree, so the greps and
# the checkout below resolve them only from there.
cd "$toplevel"

style=$(git config --get merge.conflictStyle || true)
case "$style" in
    diff3|zdiff3) exit 0 ;;
esac

# The conflict-marker-size attribute sets how many characters a marker runs
# for, and git accepts any value down to 1. A fixed seven-character pattern
# would miss a shorter marker and report the file as having none.
marker_size() {
    local size
    size=$(git check-attr conflict-marker-size -- "$1" 2>/dev/null | sed 's/.*: //')
    case "$size" in
        [1-9]|[1-9][0-9]*) echo "$size" ;;
        *) echo 7 ;;
    esac
}

has_marker() {
    local char="$1" file="$2" size="$3"
    grep -qIE "^[$char]{$size}( |\$)" -- "$file" 2>/dev/null
}

while IFS= read -r -d '' file; do
    size=$(marker_size "$file")

    # A conflicted path with no "<<<<<<<" holds a binary or delete/modify
    # conflict, or a resolution that rerere replayed. A rewrite destroys
    # that resolution.
    if ! has_marker '<' "$file" "$size"; then
        continue
    fi
    if has_marker '|' "$file" "$size"; then
        continue
    fi

    if ! git checkout --conflict=diff3 -- "$file" 2>/dev/null; then
        echo "Warning: could not rewrite conflict markers in $file" >&2
        continue
    fi

    # A merge driver named by a gitattributes "merge=" rule re-runs here.
    # Its output wins, so the re-checkout does not always add a base section.
    if has_marker '|' "$file" "$size"; then
        printf "rewrote\t%s\n" "$file"
    fi
done < <(git diff --name-only --diff-filter=U -z 2>/dev/null)
