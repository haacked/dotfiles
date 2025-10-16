# Pytest
alias pytest-changes='git bchanges | grep "test_[^/]*\.py$" | xargs pytest'

# Disk Space Management
alias disk-check='~/.dotfiles/bin/check-disk-space'
alias disk-usage='df -h'
alias disk-cleanup='~/.dotfiles/bin/disk-cleanup'
alias disk-cleanup-docker='docker container prune -f && docker image prune -f && docker volume prune -f && docker network prune -f'
alias disk-cleanup-docker-aggressive='echo "WARNING: This will remove ALL containers, images, and volumes including running PostHog containers!" && docker system prune -a -f --volumes'
alias disk-cleanup-caches='rm -rf ~/.cache/uv ~/.cache/puppeteer ~/Library/Caches/JetBrains ~/Library/Caches/Google/Chrome/Default/Cache'
alias disk-monitor-log='tail -f ~/.dotfiles/.notes/disk-monitor.log'