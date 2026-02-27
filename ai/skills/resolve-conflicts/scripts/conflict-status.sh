#!/bin/bash
# Detect the current git conflict context by reading git internals.
#
# Usage: conflict-status.sh
#
# Output format (tab-separated):
#   <context>\t<progress>\t<branch>
#
# Context values:
#   rebase      - Rebase in progress (progress shows current/total)
#   merge       - Merge in progress
#   cherry-pick - Cherry-pick in progress
#   revert      - Revert in progress
#   none        - No conflict-producing operation in progress
#
# Progress is "current/total" for rebase, empty for all other contexts.

set -euo pipefail

git_dir=$(git rev-parse --git-dir 2>/dev/null) || {
    echo "Error: not in a git repository" >&2
    exit 1
}

branch=$(git branch --show-current 2>/dev/null || echo "")

# Detect the active conflict-producing operation. Rebase stores state in one
# of two directories depending on whether it's interactive or apply-based.
if [[ -d "$git_dir/rebase-merge" || -d "$git_dir/rebase-apply" ]]; then
    context="rebase"

    if [[ -d "$git_dir/rebase-merge" ]]; then
        rebase_dir="$git_dir/rebase-merge"
    else
        rebase_dir="$git_dir/rebase-apply"
    fi

    current=""
    total=""
    if [[ -f "$rebase_dir/msgnum" ]]; then
        current=$(cat "$rebase_dir/msgnum")
    elif [[ -f "$rebase_dir/next" ]]; then
        current=$(cat "$rebase_dir/next")
    fi
    if [[ -f "$rebase_dir/end" ]]; then
        total=$(cat "$rebase_dir/end")
    fi

    # The original branch name is stored in head-name during a rebase.
    if [[ -f "$rebase_dir/head-name" ]]; then
        branch=$(sed 's|^refs/heads/||' < "$rebase_dir/head-name")
    fi

    printf "%s\t%s/%s\t%s\n" "$context" "$current" "$total" "$branch"
elif [[ -f "$git_dir/MERGE_HEAD" ]]; then
    printf "merge\t\t%s\n" "$branch"
elif [[ -f "$git_dir/CHERRY_PICK_HEAD" ]]; then
    printf "cherry-pick\t\t%s\n" "$branch"
elif [[ -f "$git_dir/REVERT_HEAD" ]]; then
    printf "revert\t\t%s\n" "$branch"
else
    printf "none\t\t%s\n" "$branch"
fi
