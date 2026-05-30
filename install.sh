#!/usr/bin/env bash
# install.sh - One-liner bootstrap for a fresh Mac.
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/haacked/dotfiles/main/install.sh | bash
#
# Or from another branch:
#   curl -fsSL https://raw.githubusercontent.com/haacked/dotfiles/main/install.sh | BRANCH=somebranch bash
#
# This installs the Xcode Command Line Tools (for git), clones the dotfiles to
# ~/.dotfiles, points the origin remote at SSH, and runs script/bootstrap.

set -euo pipefail

REPO_HTTPS="https://github.com/haacked/dotfiles.git"
REPO_SSH="git@github.com:haacked/dotfiles.git"
BRANCH="${BRANCH:-main}"
DOTFILES="$HOME/.dotfiles"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

info() { echo -e "${GREEN}✓${NC} $1"; }
warn() { echo -e "${YELLOW}⚠${NC} $1"; }
error() { echo -e "${RED}✗${NC} $1"; }

ensure_xcode_clt() {
  if xcode-select -p &>/dev/null; then
    info "Xcode Command Line Tools already installed"
    return
  fi

  info "Installing Xcode Command Line Tools (provides git)…"
  warn "Accept the macOS dialog that appears, then wait for it to finish."
  xcode-select --install &>/dev/null || true

  # Wait for the GUI installer to complete.
  until xcode-select -p &>/dev/null; do
    sleep 5
  done
  info "Xcode Command Line Tools installed"
}

clone_or_update() {
  if [ -d "$DOTFILES/.git" ]; then
    info "Existing dotfiles found at $DOTFILES, updating…"
    git -C "$DOTFILES" fetch origin "$BRANCH"
    git -C "$DOTFILES" checkout "$BRANCH"
    git -C "$DOTFILES" pull --ff-only origin "$BRANCH"
  elif [ -e "$DOTFILES" ]; then
    error "$DOTFILES exists but is not a git repo. Move it aside and re-run."
    exit 1
  else
    info "Cloning dotfiles to $DOTFILES (branch: $BRANCH)…"
    git clone --branch "$BRANCH" "$REPO_HTTPS" "$DOTFILES"
  fi

  # Prefer SSH for future pushes (keys may not exist yet; that's fine).
  git -C "$DOTFILES" remote set-url origin "$REPO_SSH"
}

main() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  haacked dotfiles installer"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  if [ "$(uname -s)" != "Darwin" ]; then
    warn "This installer targets macOS. Continuing, but your mileage may vary."
  fi

  ensure_xcode_clt
  clone_or_update

  info "Running script/bootstrap…"
  cd "$DOTFILES"
  # Redirect stdin from the terminal so bootstrap can prompt (git name/email, link conflicts).
  if [ -t 0 ]; then
    script/bootstrap
  else
    script/bootstrap < /dev/tty
  fi

  echo ""
  echo "═══════════════════════════════════════════════════════"
  info "Installation complete!"
  echo ""
  echo "Next steps:"
  echo "  • Add an SSH key to GitHub so pushes work (origin is set to SSH)."
  echo "  • Restart your shell or run: exec zsh"
  echo "  • Re-run anytime with: dot"
  echo "═══════════════════════════════════════════════════════"
  echo ""
}

main "$@"
