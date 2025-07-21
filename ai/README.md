# Remote Claude Code Access Setup

Secure remote access to multiple Claude Code sessions from your iPhone using tmux and Tailscale.

## Quick Setup

1. **Install Tailscale** on both Mac and iPhone
   - Mac: `brew install tailscale`
   - iPhone: Download Tailscale app from App Store
   - Connect both devices to same Tailscale account

2. **Install dotfiles configuration**

   ```bash
   # Link tmux config
   ln -sf ~/.dotfiles/terminal/.tmux.conf ~/.tmux.conf
   
   # Source aliases in your shell
   echo "source ~/.dotfiles/zsh/claude-aliases.zsh" >> ~/.zshrc
   source ~/.zshrc
   ```

## Usage

### Creating and Managing Sessions

```bash
# Create new Claude session
cs new bugfix ~/projects/myapp

# List all Claude sessions  
cs list

# Attach to existing session
cs attach bugfix

# Kill a session
cs kill bugfix
```

### Remote Access from iPhone

1. **Find your Mac's Tailscale IP**

   ```bash
   tailscale ip -4
   ```

2. **SSH from iPhone** (using Termius or similar)

   ```bash
   ssh youruser@100.x.x.x
   ```

3. **Manage sessions remotely**

   ```bash
   cs list                    # See all sessions
   cs attach main            # Connect to session
   tmux-status              # Quick status check
   ```

### Useful iPhone Terminal Snippets

Configure these in Termius for one-tap access:

- **List Sessions**: `cs list`
- **Attach Main**: `cs attach main || cs new main`
- **Quick Status**: `tmux-status`
- **New Session**: `cs new $name`

## Aliases Reference

- `cs` → `claude-session` (main command)
- `csn` → Create new session
- `csa` → Attach to session  
- `csl` → List sessions
- `csk` → Kill session
- `css` → Session status

## Security Notes

- Tailscale provides secure, encrypted peer-to-peer connections
- No need to expose SSH ports publicly
- Works seamlessly with dynamic IPs (DHCP)
- Sessions persist even when disconnected

## Troubleshooting

**Can't connect to session?**

```bash
cs list  # Check if session exists
tmux list-sessions  # See all tmux sessions
```

**Tailscale connection issues?**

```bash
tailscale status  # Check connection status
tailscale ping [device-name]  # Test connectivity
```
