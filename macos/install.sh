if test ! "$(uname)" = "Darwin"
  then
  exit 0
fi

# The Brewfile handles Homebrew-based app and library installs, but there may
# still be updates and installables in the Mac App Store. There's a nifty
# command line interface to it that we can use to just install everything, so
# yeah, let's do that.

echo "› sudo softwareupdate -i -a"
sudo softwareupdate -i -a

# Ensure Homebrew is in PATH for non-interactive shells (e.g., mosh, rsync over SSH)
if [ ! -f /etc/paths.d/homebrew ]; then
  echo '/opt/homebrew/bin' | sudo tee /etc/paths.d/homebrew > /dev/null
fi