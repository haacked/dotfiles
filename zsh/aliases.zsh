# Pytest
alias pytest-changes='git bchanges | grep "test_[^/]*\.py$" | xargs pytest'

# Disk Space Management
alias disk-check='~/.dotfiles/bin/check-disk-space'
alias disk-usage='df -h'
alias disk-cleanup='echo "Running comprehensive cleanup..." && brew cleanup --prune=all && yarn cache clean && pnpm store prune && docker system prune -a -f --volumes && rm -rf ~/.cache/uv ~/.cache/puppeteer && xcrun simctl delete unavailable && echo "Cleanup complete! Check disk usage with: disk-usage"'
alias disk-cleanup-docker='docker system prune -a -f --volumes'
alias disk-cleanup-caches='rm -rf ~/.cache/uv ~/.cache/puppeteer ~/Library/Caches/JetBrains ~/Library/Caches/Google/Chrome/Default/Cache'
alias disk-monitor-log='tail -f ~/.dotfiles/.notes/disk-monitor.log'