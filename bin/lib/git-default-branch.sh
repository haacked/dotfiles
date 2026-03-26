#!/usr/bin/env bash
# git-default-branch.sh - Detect the default branch for the current repository
#
# Source this file to get the detection function:
#   source "${SCRIPT_DIR}/lib/git-default-branch.sh"
#   branch=$(get_default_branch)
#
# Or run directly:
#   branch=$(path/to/git-default-branch.sh)
#
# Returns the bare branch name (e.g., "main" or "master").
# Callers needing a remote-tracking ref should prepend "origin/".

get_default_branch() {
  local base=""

  # 1. Try origin/HEAD symbolic ref (fast, local-only)
  base="$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null | sed 's|^origin/||')"

  # 2. Query the remote directly (requires network)
  if [ -z "$base" ] && git remote get-url origin >/dev/null 2>&1; then
    base="$(git remote show origin 2>/dev/null | awk '/HEAD branch/ {print $NF}')"
  fi

  # 3. Try gh CLI
  if [ -z "$base" ] && command -v gh >/dev/null 2>&1; then
    base="$(gh repo view --json defaultBranchRef -q .defaultBranchRef.name 2>/dev/null || true)"
  fi

  # 4. Check for common remote-tracking branches
  if [ -z "$base" ] && git show-ref --verify --quiet refs/remotes/origin/main 2>/dev/null; then
    base="main"
  elif [ -z "$base" ] && git show-ref --verify --quiet refs/remotes/origin/master 2>/dev/null; then
    base="master"
  fi

  # 5. Last resort
  [ -z "$base" ] && base="main"

  echo "$base"
}

# Run directly if not being sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  get_default_branch
fi
