# Sets reasonable macOS defaults.
#
# Or, in other words, set shit how I like in macOS.
#
# The original idea (and a couple settings) were grabbed from:
#   https://github.com/mathiasbynens/dotfiles/blob/master/.macos
#
# Run ./set-defaults.sh and you'll be good to go.
#
# CREDIT: https://github.com/holman/dotfiles/blob/master/macos/set-defaults.sh

# Disable press-and-hold for keys in favor of key repeat.
defaults write -g ApplePressAndHoldEnabled -bool false

# Use AirDrop over every interface. srsly this should be a default.
defaults write com.apple.NetworkBrowser BrowseAllInterfaces 1

# Always open everything in Finder's list view. This is important.
defaults write com.apple.finder FXPreferredViewStyle -string "Nlsv"

# Show the ~/Library folder.
chflags nohidden ~/Library

# Set a really fast key repeat.
defaults write NSGlobalDomain KeyRepeat -int 1

# Set the Finder prefs for showing a few different volumes on the Desktop.
defaults write com.apple.finder ShowExternalHardDrivesOnDesktop -bool true
defaults write com.apple.finder ShowRemovableMediaOnDesktop -bool true

# Show hidden files in Finder.
defaults write com.apple.finder AppleShowAllFiles -bool true

# Run the screensaver if we're in the bottom-left hot corner.
defaults write com.apple.dock wvous-bl-corner -int 5
defaults write com.apple.dock wvous-bl-modifier -int 0

# Safari's Develop menu is enabled via Safari > Settings > Advanced on modern
# macOS; the old WebKitDeveloperExtras default no longer has any effect.

# Point Alfred at its synced preferences bundle so hotkeys, workflows, snippets,
# and themes restore automatically on a fresh machine (Migration Assistant
# carries this over, but a clean install won't). Only sets the pointer; the
# bundle must already exist at ALFRED_SYNC in Google Drive. The syncfolder key
# lives in the Alfred-Preferences domain, not the main com.runningwithcrayons.Alfred
# one. The Powerpack license is per-machine and won't sync, so re-enter it once.
ALFRED_SYNC="$HOME/Library/CloudStorage/GoogleDrive-haacked@gmail.com/My Drive/Misc/alfred_preferences"
if [ -d "$ALFRED_SYNC/Alfred.alfredpreferences" ]; then
  defaults read com.runningwithcrayons.Alfred-Preferences syncfolder >/dev/null 2>&1 ||
    defaults write com.runningwithcrayons.Alfred-Preferences syncfolder -string "$ALFRED_SYNC"
fi

# Power: this Mac is remoted into (Jump Desktop), so on AC it must stay awake
# and reachable. Never auto-sleep while plugged in; let only the display sleep.
# Battery settings are left untouched so it still conserves when unplugged.
sudo pmset -c sleep 0          # never auto-sleep on AC → always reachable
sudo pmset -c displaysleep 10  # screen off after 10 min (doesn't affect remote)
sudo pmset -c womp 1           # wake for network access (backstop)

# Apply the settings that need a relaunch to take effect.
killall Finder Dock SystemUIServer 2>/dev/null || true