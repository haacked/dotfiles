#!/bin/bash
# Minimal git worktree helper - leverages git's native capabilities
# Usage: tree-me <command> [options]
#
# For auto-cd and tab completion, add this to your ~/.bashrc or ~/.zshrc:
#   source <(tree-me shellenv)
#
# This enables:
# - Automatic cd to worktree after checkout/create/pr commands
# - Tab completion for commands and branch names

set -e

# Worktree organization: ~/dev/worktrees/<repo>/<branch>
WORKTREE_ROOT="${WORKTREE_ROOT:-$HOME/dev/worktrees}"

# Show help if no arguments
show_help() {
    cat << 'EOF'
Usage: tree-me <command> [options]

Git-like worktree management with organized directory structure.

Commands:
  checkout, co <branch>         Checkout existing branch in new worktree
  create <branch> [base]        Create new branch in worktree (default: main/master)
  pr <number|url>               Checkout GitHub PR in worktree (uses gh)
  list, ls                      List all worktrees
  remove, rm <branch>           Remove a worktree
  prune                         Remove worktree administrative files
  shellenv                      Output shell function for auto-cd (source this)

Examples:
  tree-me checkout feature-branch
  tree-me create my-feature
  tree-me create my-feature develop
  tree-me pr 123
  tree-me pr https://github.com/org/repo/pull/123
  tree-me list
  tree-me remove old-branch
  tree-me prune

Setup auto-cd:
  Add to ~/.bashrc or ~/.zshrc:
    source <(tree-me shellenv)

Worktrees are organized at: $WORKTREE_ROOT/<repo>/<branch>
Set WORKTREE_ROOT to customize the location (default: ~/dev/worktrees)
EOF
}

if [ $# -eq 0 ]; then
    show_help
    exit 0
fi

# Get repo name from git
get_repo_name() {
    basename "$(git remote get-url origin 2>/dev/null || git rev-parse --show-toplevel)" .git
}

# Get default base branch
get_default_base() {
    git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo main
}

# Extract PR number from URL or number
get_pr_number() {
    local input="$1"
    if [[ "$input" =~ ^https://github.com/.*/pull/([0-9]+) ]]; then
        echo "${BASH_REMATCH[1]}"
    elif [[ "$input" =~ ^[0-9]+$ ]]; then
        echo "$input"
    else
        echo "Error: Invalid PR number or URL: $input" >&2
        exit 1
    fi
}

repo=$(get_repo_name)
command="$1"
shift

case "$command" in
    shellenv)
        cat << 'EOF'
tree-me() {
    local output
    output=$(command tree-me "$@")
    local exit_code=$?
    echo "$output"
    if [ $exit_code -eq 0 ]; then
        local cd_path=$(echo "$output" | grep "^TREE_ME_CD:" | cut -d: -f2-)
        [ -n "$cd_path" ] && cd "$cd_path"
    fi
    return $exit_code
}

# Bash completion
if [ -n "$BASH_VERSION" ]; then
    _tree_me_complete() {
        local cur prev commands
        COMPREPLY=()
        cur="${COMP_WORDS[COMP_CWORD]}"
        prev="${COMP_WORDS[COMP_CWORD-1]}"
        commands="checkout co create pr list ls remove rm prune help shellenv"

        # Complete commands if first argument
        if [ $COMP_CWORD -eq 1 ]; then
            COMPREPLY=( $(compgen -W "$commands" -- "$cur") )
            return 0
        fi

        # Complete branch names for checkout/remove/rm
        case "$prev" in
            checkout|co|remove|rm)
                local branches
                branches=$(git worktree list 2>/dev/null | awk 'NR>1 {match($0, /\[([^]]+)\]/, arr); if (arr[1]) print arr[1]}')
                COMPREPLY=( $(compgen -W "$branches" -- "$cur") )
                return 0
                ;;
        esac
    }
    complete -F _tree_me_complete tree-me
fi

# Zsh completion
if [ -n "$ZSH_VERSION" ]; then
    _tree_me_complete_zsh() {
        local -a commands branches
        commands=(
            'checkout:Checkout existing branch in new worktree'
            'co:Checkout existing branch in new worktree'
            'create:Create new branch in worktree'
            'pr:Checkout GitHub PR in worktree'
            'list:List all worktrees'
            'ls:List all worktrees'
            'remove:Remove a worktree'
            'rm:Remove a worktree'
            'prune:Remove worktree administrative files'
            'help:Show help'
            'shellenv:Output shell function for auto-cd'
        )

        if (( CURRENT == 2 )); then
            _describe 'command' commands
        elif (( CURRENT == 3 )); then
            case "$words[2]" in
                checkout|co|remove|rm)
                    branches=(${(f)"$(git worktree list 2>/dev/null | awk 'NR>1 {match($0, /\[([^]]+)\]/, arr); if (arr[1]) print arr[1]}')"})
                    _describe 'branch' branches
                    ;;
            esac
        fi
    }
    compdef _tree_me_complete_zsh tree-me
fi
EOF
        ;;

    checkout|co)
        branch="${1:?Branch name required. Usage: tree-me checkout <branch>}"
        path="$WORKTREE_ROOT/$repo/$branch"

        # Check if worktree already exists
        if git worktree list | grep -q "\[$branch\]"; then
            existing=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
            echo "✓ Worktree already exists: $existing"
            echo "TREE_ME_CD:$existing"
            exit 0
        fi

        # Check if branch exists
        if git show-ref --verify --quiet "refs/heads/$branch" || \
           git show-ref --verify --quiet "refs/remotes/origin/$branch"; then
            git worktree add "$path" "$branch"
            echo "✓ Worktree created at: $path"
            echo "TREE_ME_CD:$path"
        else
            echo "Error: Branch '$branch' does not exist" >&2
            echo "Use 'tree-me create $branch' to create a new branch" >&2
            exit 1
        fi
        ;;

    create)
        branch="${1:?Branch name required. Usage: tree-me create <branch> [base-branch]}"
        base="${2:-$(get_default_base)}"
        path="$WORKTREE_ROOT/$repo/$branch"

        # Check if worktree already exists
        if git worktree list | grep -q "\[$branch\]"; then
            existing=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
            echo "✓ Worktree already exists: $existing"
            echo "TREE_ME_CD:$existing"
            exit 0
        fi

        # Create new branch
        git worktree add "$path" -b "$branch" "$base"
        echo "✓ Worktree created at: $path"
        echo "TREE_ME_CD:$path"
        ;;

    pr)
        input="${1:?PR number or URL required. Usage: tree-me pr <number|url>}"
        pr_number=$(get_pr_number "$input")

        # Check if gh is installed
        if ! command -v gh >/dev/null 2>&1; then
            echo "Error: 'gh' CLI not found. Install it from https://cli.github.com" >&2
            exit 1
        fi

        # Use gh to checkout PR in a worktree
        branch="pr-$pr_number"
        path="$WORKTREE_ROOT/$repo/$branch"

        # Check if worktree already exists
        if git worktree list | grep -q "\[$branch\]"; then
            existing=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
            echo "✓ Worktree already exists: $existing"
            echo "TREE_ME_CD:$existing"
            exit 0
        fi

        # Fetch the PR and create worktree
        git fetch origin "pull/$pr_number/head:$branch" 2>/dev/null || true
        git worktree add "$path" "$branch"
        echo "✓ PR #$pr_number checked out at: $path"
        echo "TREE_ME_CD:$path"
        ;;

    list|ls)
        git worktree list
        ;;

    remove|rm)
        branch="${1:?Branch name required. Usage: tree-me remove <branch>}"
        existing=$(git worktree list | grep "\[$branch\]" | awk '{print $1}')
        if [ -z "$existing" ]; then
            echo "Error: No worktree found for branch: $branch" >&2
            exit 1
        fi
        git worktree remove "$existing"
        echo "✓ Removed worktree: $existing"
        ;;

    prune)
        git worktree prune
        echo "✓ Pruned stale worktree administrative files"
        ;;

    help|--help|-h)
        show_help
        ;;

    *)
        echo "Error: Unknown command '$command'" >&2
        echo "Run 'tree-me help' for usage information" >&2
        exit 1
        ;;
esac
