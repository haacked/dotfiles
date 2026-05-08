#!/usr/bin/env bash
# git-worktree.sh - Helpers for parsing `git worktree` output
#
# Source this file:
#   source "${SCRIPT_DIR}/lib/git-worktree.sh"
#
# Uses the documented porcelain format and literal (not regex) matching, so
# branch names with metacharacters and paths with spaces are handled safely.

# Print the path of the worktree for the given branch, or nothing if none.
worktree_path_for() {
  local branch="$1"
  git worktree list --porcelain | awk -v target="branch refs/heads/$branch" '
    /^worktree / { path = substr($0, 10) }
    $0 == target { print path; exit }
  '
}

# Print "<branch>\t<path>" for each non-main worktree, one per line.
# The main worktree (always first in `git worktree list`) is excluded.
# Detached and bare worktrees are skipped (they have no branch).
list_worktrees_excluding_main() {
  git worktree list --porcelain | awk '
    function flush() {
      if (branch != "") {
        count++
        if (count > 1) printf "%s\t%s\n", branch, path
      }
      branch = ""; path = ""
    }
    /^worktree / { flush(); path = substr($0, 10) }
    /^branch refs\/heads\// { branch = substr($0, 19) }
    END { flush() }
  '
}
