# Pytest
alias pytest-changes='git bchanges | grep "test_[^/]*\.py$" | xargs pytest'

# Disk Space Management
alias disk-check='~/.dotfiles/bin/check-disk-space'
alias disk-free='df -h /System/Volumes/Data | tail -1 | awk "{print \$4}"'
alias disk-usage='df -h / /System/Volumes/Data | grep -v "^Filesystem"'
alias disk-usage-all='df -h'
alias disk-cleanup='~/.dotfiles/bin/disk-cleanup'
alias disk-cleanup-aggressive='~/.dotfiles/bin/disk-cleanup --aggressive'
alias disk-cleanup-docker='~/.dotfiles/bin/disk-cleanup --module docker'
alias disk-cleanup-docker-aggressive='~/.dotfiles/bin/disk-cleanup --module docker --aggressive'
alias disk-cleanup-rust='~/.dotfiles/bin/disk-cleanup --module rust'
alias disk-cleanup-rust-aggressive='~/.dotfiles/bin/disk-cleanup --module rust --aggressive'
alias disk-cleanup-caches='~/.dotfiles/bin/disk-cleanup --module python'
alias disk-monitor-log='tail -f ~/.dotfiles/.notes/disk-monitor.log'