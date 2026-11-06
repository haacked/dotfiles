#!/usr/bin/env bash
# install.sh - One-liner bootstrap for a fresh Mac.
#
# On Linux it installs only the Claude Code setup. A Coder dev box runs it from
# its own clone on every start. See install_linux.
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

  # Wait for the GUI installer to complete, but don't hang forever if the user
  # cancels the dialog or it never starts. 30 minutes covers a slow download.
  local waited=0 timeout=1800
  until xcode-select -p &>/dev/null; do
    if [ "$waited" -ge "$timeout" ]; then
      error "Timed out waiting for Xcode Command Line Tools."
      error "Run 'xcode-select --install', let it finish, then re-run this installer."
      exit 1
    fi
    sleep 5
    waited=$((waited + 5))
  done
  info "Xcode Command Line Tools installed"
}

clone_or_update() {
  if [ -d "$DOTFILES/.git" ]; then
    info "Existing dotfiles found at $DOTFILES, updating…"
    # Fetch over HTTPS so updates work even before an SSH key is set up (a
    # prior run may have already pointed origin at SSH).
    git -C "$DOTFILES" remote set-url origin "$REPO_HTTPS"
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

# Coder clones the repo outside ~/.dotfiles. The Claude installers, hooks, and
# skills read paths under ~/.dotfiles. This link makes those paths resolve to
# the checkout.
link_dotfiles_checkout() {
  local checkout="$1"
  if [ ! -e "$DOTFILES" ]; then
    ln -sfn "$checkout" "$DOTFILES"
  elif [ "$(cd "$DOTFILES" && pwd -P)" != "$checkout" ]; then
    error "$DOTFILES is not this checkout ($checkout). Move it aside and re-run."
    exit 1
  fi
  info "$DOTFILES points at $checkout"
}

# Installs only the Claude Code setup. script/bootstrap prompts for input and
# links ~/.gitconfig and ~/.zshrc, which the dev box template owns. It skips MCP
# registration because `claude mcp add` rewrites ~/.claude.json. Coder rewrites
# ~/.claude/CLAUDE.md on every start. That write follows a symlink into the
# repo, so the shared instructions load as a user rule.
install_linux() {
  local checkout
  checkout=$(cd "$(dirname "${BASH_SOURCE[0]:-}")" && pwd -P)
  if [ ! -f "$checkout/ai/install-claude.sh" ]; then
    error "On Linux, run install.sh from a clone of $REPO_HTTPS."
    exit 1
  fi

  link_dotfiles_checkout "$checkout"
  "$DOTFILES/ai/install-claude.sh" --no-mcp --instructions-as-rule

  echo ""
  info "Installation complete!"
}

main() {
  echo ""
  echo "═══════════════════════════════════════════════════════"
  echo "  haacked dotfiles installer"
  echo "═══════════════════════════════════════════════════════"
  echo ""

  case "$(uname -s)" in
    Darwin) ;;
    Linux)
      install_linux
      return
      ;;
    *)
      error "This installer only supports macOS and Linux."
      exit 1
      ;;
  esac

  ensure_xcode_clt
  clone_or_update

  info "Running script/bootstrap…"
  cd "$DOTFILES"
  # bootstrap prompts (git name/email, link conflicts), so it needs a real
  # terminal on stdin. When piped via `curl | bash`, stdin is the pipe, so read
  # from /dev/tty instead — but only if a controlling terminal actually exists
  # (it won't under CI or headless automation), otherwise fail clearly.
  if [ -t 0 ]; then
    script/bootstrap
  elif [ -r /dev/tty ]; then
    script/bootstrap < /dev/tty
  else
    error "No controlling terminal available for bootstrap prompts."
    error "Clone the repo and run 'script/bootstrap' from an interactive shell instead."
    exit 1
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
