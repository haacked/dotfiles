#!/bin/bash
# Homebrew cleanup module
# Cleans Homebrew packages, cache, and downloads

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_homebrew() {
    local mode="${1:-conservative}"

    if ! command -v brew >/dev/null 2>&1; then
        log_message "Homebrew not installed, skipping Homebrew cleanup"
        return 0
    fi

    log_message "Running Homebrew cleanup (mode: $mode)..."

    # Always prune all old versions
    run_cleanup "Homebrew cleanup" "brew cleanup --prune=all"

    # Homebrew cask downloads cleanup
    if [ -d "$HOME/Library/Caches/Homebrew/downloads" ]; then
        run_cleanup "Homebrew cask downloads cleanup" "rm -rf ~/Library/Caches/Homebrew/downloads/*"
    fi

    # Aggressive mode: also clean Homebrew cache
    if [ "$mode" = "aggressive" ]; then
        if [ -d "$HOME/Library/Caches/Homebrew" ]; then
            run_cleanup "Homebrew cache (aggressive)" "rm -rf ~/Library/Caches/Homebrew/*"
        fi
    fi
}
