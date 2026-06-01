#!/bin/sh
#
# Homebrew
#
# This installs some of the common dependencies needed (or at least desired)
# using Homebrew.

# Check for Homebrew
if ! command -v brew >/dev/null 2>&1
then
  echo "  Installing Homebrew for you."

  NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
fi

# Make brew available on PATH for the rest of this script (Apple Silicon installs
# to /opt/homebrew, which isn't on PATH until the shell is reconfigured).
if ! command -v brew >/dev/null 2>&1
then
  if test -x /opt/homebrew/bin/brew
  then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif test -x /usr/local/bin/brew
  then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# Bail out early with a clear message rather than letting every later `brew`
# call fail confusingly if the install or PATH setup above didn't take.
if ! command -v brew >/dev/null 2>&1
then
  echo "  Homebrew is not available on PATH. Install it manually from https://brew.sh and re-run." >&2
  exit 1
fi

function install() {
  app=$1
  cask=${2:-}

cat << EOF

-> Installing ${app}...
EOF

  if [[ x"$OS" == x"Windows" ]]; then
    scoop install ${app}
  else
    if [[ ! "$cask" ]]; then
      brew list ${app} >/dev/null || brew install ${app}
    else
      brew list ${app} --cask >/dev/null || brew install ${app} --cask
    fi
  fi

cat << EOF

-> ${app} installed
EOF
}

install 1password yes
install argocd
install cowsay
install font-jetbrains-mono-nerd-font yes
install fortune
install gh
install git-filter-repo
install go
install google-drive yes
install iterm2 yes
install jetbrains-toolbox yes
install markdownlint-cli2
install mergiraf
install mosh
install ngrok yes
install nvm
install OneDrive yes
install openssl
install postman yes
install powershell yes
install pulumi/tap/pulumi
install readline
install rbenv
install ruby-install
install secretive yes
install slack yes
install spotify yes
install sqlite3
install visual-studio-code yes
install wezterm yes
install xz
install zed yes
install zlib
install zsh

# --- Developer tooling (this repo's shell config and scripts depend on these) ---
install direnv
install jq
install yq
install fzf
install shellcheck
install shfmt
install ruff
install pipx
install helm
install kubectx
install watchman
install withgraphite/tap/graphite
install oven-sh/bun/bun
install flox yes
install orbstack yes
install ghostty yes
install supacode yes
install copilot-cli yes

# --- PostHog local development stack ---
install postgresql@14
install postgis
install redis
install librdkafka
install stripe/stripe-cli/stripe
install mitmproxy yes
install proxyman yes

# --- iOS development (posthog-ios) ---
install swiftformat
install swiftlint
install ios-deploy
install xcodes yes
install zulu@8 yes
brew tap peripheryapp/periphery
install periphery yes

# --- .NET and cloud ---
install azure-cli
install azure/functions/azure-functions-core-tools@4

# --- Other apps and utilities ---
install jump-desktop-connect yes
install pgadmin4 yes
install httpie
install cloc
install bfg

gh extension install seachicken/gh-poi

# Install Rust
if test ! $(which rustup)
then
  curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh
fi

# You may need to run these commands for ruby-installer to work.
# export PATH="/opt/homebrew/opt/openssl@1.1/bin:$PATH"
# export PKG_CONFIG_PATH="/opt/homebrew/opt/openssl@1.1/lib/pkgconfig"
# export LDFLAGS="-L/opt/homebrew/opt/openssl@1.1/lib"
# export CPPFLAGS="-I/opt/homebrew/opt/openssl@1.1/include"
ruby-install ruby 3.1.3
gem install jekyll --user-install

curl https://pyenv.run | bash

brew cleanup
rm -f -r /Library/Caches/Homebrew/*

exit 0
