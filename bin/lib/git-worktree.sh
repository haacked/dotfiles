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

# Print "<kind>\t<name>\t<path>" for non-main worktrees, using branch names
# when attached and HEAD SHAs when detached.
list_removable_worktrees() {
  git worktree list --porcelain | awk '
    /^worktree / { count++; path = substr($0, 10) }
    /^HEAD / { head = substr($0, 6) }
    count > 1 && /^branch refs\/heads\// { printf "branch\t%s\t%s\n", substr($0, 19), path }
    count > 1 && /^detached$/ { printf "detached\t%s\t%s\n", head, path }
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

# Gives the owner write permission on every directory under <path>.
make_writable() {
  find "$1" -type d ! -perm -u+w -exec chmod u+w {} +
}

# Succeeds when `git worktree remove` with <force> -f flags will refuse the
# worktree at <path> because it is the main worktree, is locked, or has changes.
# git also refuses a worktree that has populated submodules. This check misses
# that case, and the owner then gains write permission on directories that
# they already own.
worktree_remove_refused() {
  local path="$1" force="$2" git_dir
  git_dir=$(git -C "$path" rev-parse --absolute-git-dir 2>/dev/null) || return 1
  if [ "$git_dir" = "$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)" ]; then
    return 0
  fi
  if [ "$force" -lt 2 ] && [ -e "$git_dir/locked" ]; then
    return 0
  fi
  [ "$force" -lt 1 ] && [ -n "$(git -C "$path" status --porcelain --ignore-submodules=none 2>/dev/null)" ]
}

# Runs `git worktree remove` with the given arguments, which are -f/--force
# flags and one worktree path.
#
# Go makes its module cache read-only, so `git worktree remove` fails partway
# through it. git then deletes the worktree's admin dir anyway, which leaves a
# checkout that no worktree command can see. This makes every directory under
# the path writable first. It leaves permissions alone when the directory is
# missing or git will refuse the removal. It does not run git when a directory
# stays read-only or unreadable.
worktree_remove() {
  local arg path force=0
  for arg in "$@"; do
    case "$arg" in
      -f|--force) force=$((force + 1)) ;;
      *) path="$arg" ;;
    esac
  done

  if [ -d "$path" ] && ! worktree_remove_refused "$path" "$force" && ! make_writable "$path"; then
    echo "error: could not make every directory under $path writable" >&2
    return 1
  fi

  git worktree remove "$@"
}
