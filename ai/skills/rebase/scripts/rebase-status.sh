#!/bin/bash
# Detect the current git rebase state by reading git internals.
#
# Usage: rebase-status.sh
#
# Output format (tab-separated):
#   <state>\t<current>\t<total>\t<target>\t<branch>
#
# States:
#   idle        - No rebase in progress
#   conflict    - Rebase paused due to conflicts
#   in-progress - Rebase paused (no conflicts, needs --continue)
#
# When idle, current/total/target are empty and branch is the current branch.

set -euo pipefail

git_dir=$(git rev-parse --git-dir 2>/dev/null) || {
    echo "Error: not in a git repository" >&2
    exit 1
}

branch=$(git branch --show-current 2>/dev/null || echo "")

# Determine which rebase directory is active. Interactive and non-interactive
# rebases store their state in different locations.
rebase_dir=""
if [[ -d "$git_dir/rebase-merge" ]]; then
    rebase_dir="$git_dir/rebase-merge"
elif [[ -d "$git_dir/rebase-apply" ]]; then
    rebase_dir="$git_dir/rebase-apply"
fi

if [[ -z "$rebase_dir" ]]; then
    printf "idle\t\t\t\t%s\n" "$branch"
    exit 0
fi

# Read progress counters from the rebase state directory.
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

# Read the target (onto) commit and resolve it to a friendly branch name.
target=""
if [[ -f "$rebase_dir/onto" ]]; then
    onto_sha=$(cat "$rebase_dir/onto")
    target=$(git name-rev --name-only --refs='refs/remotes/origin/*' "$onto_sha" 2>/dev/null || echo "$onto_sha")
fi

# The original branch name is stored in head-name during a rebase.
if [[ -f "$rebase_dir/head-name" ]]; then
    branch=$(cat "$rebase_dir/head-name" | sed 's|^refs/heads/||')
fi

# Check for unmerged files to distinguish conflict from in-progress.
if [[ -n $(git diff --name-only --diff-filter=U 2>/dev/null) ]]; then
    state="conflict"
else
    state="in-progress"
fi

printf "%s\t%s\t%s\t%s\t%s\n" "$state" "$current" "$total" "$target" "$branch"
