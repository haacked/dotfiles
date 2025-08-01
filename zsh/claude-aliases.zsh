# Claude Code and tmux aliases for remote access

# Claude session management
alias cs='claude-session'
alias csn='claude-session new'
alias csa='claude-session attach'
alias csl='claude-session list'
alias csk='claude-session kill'
alias cska='claude-session killall'
alias css='claude-session status'

# Quick tmux operations
alias tn='tmux new-session -d -s'
alias ta='tmux attach-session -t'
alias tl='tmux list-sessions'
alias tk='tmux kill-session -t'
alias tka='tmux kill-server'

# Tmux session shortcuts for common projects
alias claude-main='claude-session attach main 2>/dev/null || claude-session new main'
alias claude-test='claude-session attach test 2>/dev/null || claude-session new test'
alias claude-debug='claude-session attach debug 2>/dev/null || claude-session new debug'

# Remote-friendly tmux commands
alias tmux-status='tmux list-sessions -F "#{session_name}: #{session_windows} windows"'
alias tmux-clean='tmux kill-session -a'  # Kill all sessions except current

# Disk Space Management
alias disk-check='~/.dotfiles/bin/check-disk-space'
alias disk-usage='df -h'
alias disk-cleanup='echo "Running comprehensive cleanup..." && brew cleanup --prune=all && yarn cache clean && pnpm store prune && docker system prune -a -f --volumes && rm -rf ~/.cache/uv ~/.cache/puppeteer && xcrun simctl delete unavailable && echo "Cleanup complete! Check disk usage with: disk-usage"'
alias disk-cleanup-docker='docker system prune -a -f --volumes'
alias disk-cleanup-caches='rm -rf ~/.cache/uv ~/.cache/puppeteer ~/Library/Caches/JetBrains ~/Library/Caches/Google/Chrome/Default/Cache'
alias disk-monitor-log='tail -f ~/.dotfiles/.notes/disk-monitor.log'