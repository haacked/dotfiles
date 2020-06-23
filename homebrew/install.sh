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

brew list node || brew install node

brew cask list dotnet-sdk || brew cask install dotnet-sdk
brew cask list signal || brew cask install signal
brew cask list visual-studio-code || brew cask install visual-studio-code
brew cask list slack || brew cask install slack
brew cask list whatsapp || brew cask install whatsapp
brew cask list google-chrome || brew cask install google-chrome
brew cask list spotify || brew cask install spotify
brew cask list 1password || brew cask install 1password
brew cask list github-desktop || brew cask install github-desktop
brew cask list OneDrive || brew cask install OneDrive
brew cask list ngrok || brew cask install ngrok
brew cask list powershell || brew cask install powershell


brew cleanup
rm -f -r /Library/Caches/Homebrew/*

exit 0
