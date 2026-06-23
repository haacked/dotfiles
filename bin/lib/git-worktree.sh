#!/usr/bin/env bash
# git-worktree.sh - Helpers for parsing and creating git worktrees
#
# Source this file:
#   source "${SCRIPT_DIR}/lib/git-worktree.sh"
#
# Parsing uses the documented porcelain format and literal (not regex)
# matching, so branch names with metacharacters and paths with spaces are
# handled safely.

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

# Create a worktree at <path> on branch <branch>, starting at <committish>.
# Prints the worktree's path on stdout; git's own output goes to stderr so the
# stdout capture stays clean for the caller.
#
# Idempotent across the common re-run cases:
#   - branch already has a worktree -> print its existing path, touch nothing
#   - branch exists without a worktree -> attach a worktree to it (ignores
#     <committish>, since the branch already points somewhere)
#   - neither exists -> create the branch at <committish> and its worktree
#
# Runs `git` in the current directory, so call it from inside the target repo
# (any of its worktrees works). Returns non-zero if `git worktree add` fails.
worktree_create() {
  local path="$1" branch="$2" committish="$3"

  local existing
  existing=$(worktree_path_for "$branch")
  if [[ -n "$existing" ]]; then
    echo "$existing"
    return 0
  fi

  if git show-ref --verify --quiet "refs/heads/${branch}"; then
    git worktree add "$path" "$branch" >&2 || return 1
  else
    git worktree add -b "$branch" "$path" "$committish" >&2 || return 1
  fi

  echo "$path"
}
