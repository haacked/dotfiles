#!/bin/sh
#
# SSH configuration setup

# Create the sockets directory for SSH multiplexing
mkdir -p ~/.ssh/sockets
echo "✓ Created ~/.ssh/sockets directory"

# Add Include directive to ~/.ssh/config if not already present
INCLUDE_LINE="Include ~/.dotfiles/ssh/config"

if [ ! -f ~/.ssh/config ]; then
  echo "$INCLUDE_LINE" > ~/.ssh/config
  echo "✓ Created ~/.ssh/config with dotfiles Include"
elif ! grep -qF "$INCLUDE_LINE" ~/.ssh/config; then
  if grep -q "Include ~/.orbstack/ssh/config" ~/.ssh/config; then
    sed -i '' "s|Include ~/.orbstack/ssh/config|Include ~/.orbstack/ssh/config\\
$INCLUDE_LINE|" ~/.ssh/config
  else
    # Prepend to the file
    printf '%s\n\n' "$INCLUDE_LINE" | cat - ~/.ssh/config > /tmp/ssh_config_tmp \
      && mv /tmp/ssh_config_tmp ~/.ssh/config
  fi
  echo "✓ Added $INCLUDE_LINE to ~/.ssh/config"
else
  echo "✓ $INCLUDE_LINE already in ~/.ssh/config"
fi
