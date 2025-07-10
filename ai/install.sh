#!/bin/sh

export ZSH=$HOME/.dotfiles

# Ensure ~/.claude directory exists
mkdir -p ~/.claude

# Copy Claude configuration files
cp $ZSH/ai/CLAUDE.md ~/.claude/CLAUDE.md
cp $ZSH/ai/settings.json ~/.claude/settings.json