# Remote SSH quality-of-life (Termius/Blink)
#
# Auto-attach to a tmux session when logging in over SSH, so the user
# always lands in a persistent workspace. Skips non-interactive shells
# (scp/rsync) and avoids nesting tmux inside tmux.
#
# Set NO_AUTO_TMUX=1 before sourcing to disable for specific users/hosts.

[[ -o interactive ]] || return

if [[ -n "$SSH_CONNECTION" && -z "$TMUX" && -z "$NO_AUTO_TMUX" ]]; then
  tmux attach -t main 2>/dev/null || tmux new -s main
fi
