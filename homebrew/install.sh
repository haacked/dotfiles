#!/bin/sh
#
# Homebrew
#
# This installs some of the common dependencies needed (or at least desired)
# using Homebrew.

# Check for Homebrew
if test ! $(which brew)
then
  echo "  Installing Homebrew for you."

  # Install the correct homebrew for each OS type
  if test "$(uname)" = "Darwin"
  then
    ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/master/install)"
  elif test "$(expr substr $(uname -s) 1 5)" = "Linux"
  then
    ruby -e "$(curl -fsSL https://raw.githubusercontent.com/Linuxbrew/install/master/install)"
  fi

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

install gh
install iterm2 yes
install zsh
install ngrok yes
install visual-studio-code yes
install slack yes
install google-chrome yes
install spotify yes
install 1password yes
install github-desktop yes
install OneDrive yes
install powershell yes
install google-drive yes
install jetbrains-toolbox yes
install postman yes
install nodenv
nodenv install
install keyboard-maestro yes
install overmind yes
install pulumi/tap/pulumi
install openssl
install readline
install sqlite3 
install zlib
install chruby
install ruby-install
install xz

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
