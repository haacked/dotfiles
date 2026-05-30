#!/bin/sh
#
# .NET SDK
#
# Installs the .NET SDK directly from Microsoft's signed .pkg into
# /usr/local/share/dotnet, which zsh/zshrc.symlink already adds to PATH.
# We use the official installer rather than Homebrew so the SDK and global
# tools live where the rest of this repo's config expects them.

set -e

# Already installed? The .pkg drops the SDK under /usr/local/share/dotnet.
if [ -x /usr/local/share/dotnet/dotnet ]; then
  echo "-> .NET SDK already installed at /usr/local/share/dotnet"
  exit 0
fi

arch="$(uname -m)"
case "$arch" in
  arm64) pkg_arch="osx-arm64" ;;
  x86_64) pkg_arch="osx-x64" ;;
  *) echo "-> Unsupported architecture for .NET install: $arch" ; exit 0 ;;
esac

# aka.ms redirects to the latest LTS SDK .pkg for this architecture.
pkg_url="https://aka.ms/dotnet/LTS/dotnet-sdk-${pkg_arch}.pkg"
pkg_path="$(mktemp -d)/dotnet-sdk.pkg"

echo "-> Downloading .NET LTS SDK ($pkg_arch)…"
curl -fSL "$pkg_url" -o "$pkg_path"

echo "-> Installing .NET SDK (requires sudo)…"
sudo installer -pkg "$pkg_path" -target /

rm -f "$pkg_path"
echo "-> .NET SDK installed"
