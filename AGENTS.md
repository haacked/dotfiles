# Dotfiles Project

This repository manages shell configuration, aliases, completions, and utility scripts.

## Shell Configuration

`~/.zshrc` is a symlink to `zsh/zshrc.symlink` (created by `script/bootstrap`). All interactive shell configuration lives in this file.

## Portable Skills

A portable skill can't use the `~/.dotfiles/` path exception in `ai/AGENTS.md`, because a cloud agent run unpacks it into a sandbox with no clone of this repo. The portable skills section of `ai/README.md` says which skills those are and what they may reference.
