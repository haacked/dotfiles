#!/usr/bin/env bash
set -e

if [ -f "$HOME/.iterm2_shell_integration.zsh" ]; then
  echo "iTerm2 shell integration already installed."
else
  echo "Installing iTerm2 shell integration..."
  curl -L https://iterm2.com/shell_integration/zsh -o "$HOME/.iterm2_shell_integration.zsh"
fi

if [ -d "$HOME/.oh-my-zsh" ]; then
  echo "oh-my-zsh already installed."
else
  echo "Installing oh-my-zsh..."
  # KEEP_ZSHRC: don't clobber our dotfiles ~/.zshrc symlink.
  # RUNZSH:     don't spawn a new shell at the end of the installer.
  # CHSH:       don't change the login shell (macOS already defaults to zsh).
  RUNZSH=no CHSH=no KEEP_ZSHRC=yes \
    sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi
