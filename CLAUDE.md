# Dotfiles Project

This repository manages shell configuration, aliases, completions, and utility scripts.

## Shell Configuration

`~/.zshrc` lives outside this repo and should not be edited directly for changes that can be tracked here. Instead, add shell configuration (exports, sourcing, functions, etc.) to `zsh/.bash_exports`, which is sourced by `~/.zshrc`. This keeps all changes version-controlled in this repo.

Key files:

- `zsh/.bash_exports` — environment variables, PATH setup, tool initialization, and sourcing of other dotfiles
- `zsh/aliases.zsh` — shell aliases
- `zsh/*-completion.zsh` — tab completion scripts (sourced from `.bash_exports`)
