# tree-me: Minimal Git Worktree Helper

A tiny wrapper around git's native worktree commands. **Leverages git instead of reinventing it.**

## Philosophy

Use git's built-in capabilities. This is a minimal script that adds convention (organized paths) while letting git handle validation, errors, and all the hard work.

## Installation

The `tree-me` script is in your PATH via `~/.dotfiles/bin`.

### Setup Auto-CD and Tab Completion

Add this to your `~/.bashrc` or `~/.zshrc`:

```bash
source <(tree-me shellenv)
```

This enables:

- **Auto-CD**: Automatically changes to the worktree directory after `create`, `checkout`, or `pr` commands
- **Tab Completion**: Tab complete commands and branch names

### Usage

```bash
tree-me create feature-branch         # Create new branch (auto-cd enabled)
tree-me co feature-branch             # Checkout existing branch (alias for checkout)
tree-me pr 123                        # Checkout GitHub PR (auto-cd enabled)
tree-me ls                            # List all worktrees (alias for list)
tree-me rm feature-branch             # Remove worktree (tab completion for branches)
tree-me prune                         # Clean up stale worktree files
```

## Detailed Usage

### Create a new branch

```bash
tree-me create feature-branch              # Creates from main/master
tree-me create feature-branch develop      # Creates from develop
```

**What it does:**

- Creates worktree at `~/dev/worktrees/<repo>/<branch>`
- Creates new branch from base (default: main/master)
- **Automatically cds into the worktree** (when using `source <(tree-me shellenv)`)
- Lets **git handle all validation and errors**

### Checkout an existing branch

```bash
tree-me checkout feature-branch     # Full command
tree-me co feature-branch           # Shorter alias
```

Checks out an existing local or remote branch in a new worktree.

### Checkout a GitHub PR

```bash
tree-me pr 123                              # By PR number
tree-me pr https://github.com/org/repo/pull/456  # By URL
```

Fetches the PR and creates a worktree at `~/dev/worktrees/<repo>/pr-123`.

### List worktrees

```bash
tree-me list    # or tree-me ls
```

Shows all worktrees with their paths and checked out branches.

### Remove a worktree

```bash
tree-me remove branch-name          # Full command
tree-me rm branch-name              # Shorter alias (supports tab completion)
```

Removes the worktree for the specified branch. Use tab completion to see available branches.

### Clean up stale worktrees

```bash
tree-me prune
```

Removes administrative files for worktrees that no longer exist.

## Directory Structure

```text
~/dev/worktrees/
├── dotfiles/
│   ├── main/
│   └── feature-1/
└── posthog/
    ├── main/
    └── bug-fix/
```

## Configuration

Set custom worktree location:

```bash
export WORKTREE_ROOT=~/projects/worktrees
```

## Why This Approach?

**Principle:** Don't recreate what git does well. Add only the minimal convention needed.

**Before (original design):** 544 lines of bash reinventing git worktree with security vulnerabilities
**After (this implementation):** Minimal wrapper around git's native commands with a git-like interface

**Benefits:**

- ✅ Leverages git's battle-tested worktree implementation
- ✅ Git handles all validation, errors, and edge cases
- ✅ No security vulnerabilities from custom path handling
- ✅ No maintenance burden
- ✅ Works exactly like git (because it is git)
- ✅ Intuitive git-like subcommand interface
- ✅ Auto-CD and tab completion for smooth workflow
- ✅ Simple and easy to understand

## What Git Already Does

This tool is just a thin wrapper. Git does the real work:

| Feature | Native Git Command |
|---------|-------------------|
| Create worktree | `git worktree add <path> -b <branch> <base>` |
| List worktrees | `git worktree list` |
| Remove worktree | `git worktree remove <path>` |
| Prune stale | `git worktree prune` |

## Examples

```bash
# Create a new feature branch
tree-me create haacked/new-feature

# Checkout existing branch
tree-me co main

# Branch from develop instead of main
tree-me create haacked/fix-bug develop

# Checkout a PR
tree-me pr 123

# List all worktrees
tree-me ls

# Remove a worktree (use tab to see available branches)
tree-me rm haacked/old-feature

# Clean up stale worktrees
tree-me prune
```

## Extending

Need interactive selection with fzf?

```bash
# Add to ~/.zshrc or ~/.bashrc
wtf() {
    local worktree=$(git worktree list | fzf | awk '{print $1}')
    [ -n "$worktree" ] && cd "$worktree"
}
```

Need machine-readable output?

```bash
git worktree list --porcelain
```

## See Also

- `git worktree --help` - Full git worktree documentation
- `gh pr checkout --help` - GitHub PR checkout
