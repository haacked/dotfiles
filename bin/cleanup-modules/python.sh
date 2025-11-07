#!/bin/bash
# Python cleanup module
# Cleans UV, pip, pytest, and other Python caches

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_python() {
    local mode="${1:-conservative}"

    log_message "Running Python cleanup (mode: $mode)..."

    # UV cache cleanup
    if [ -d "$HOME/.cache/uv" ]; then
        run_cleanup "UV cache cleanup" "rm -rf ~/.cache/uv"
    fi

    # Puppeteer cache cleanup
    if [ -d "$HOME/.cache/puppeteer" ]; then
        run_cleanup "Puppeteer cache cleanup" "rm -rf ~/.cache/puppeteer"
    fi

    # pip cache cleanup
    if [ -d "$HOME/.cache/pip" ]; then
        run_cleanup "pip cache cleanup" "rm -rf ~/.cache/pip"
    fi

    # pytest cache cleanup
    if [ -d "$HOME/.cache/pytest" ]; then
        run_cleanup "pytest cache cleanup" "rm -rf ~/.cache/pytest"
    fi

    # Aggressive mode: also clean __pycache__ directories
    if [ "$mode" = "aggressive" ]; then
        log_message "Aggressive mode: cleaning __pycache__ directories..."
        find "$HOME/dev" -type d -name __pycache__ -exec rm -rf {} + 2>/dev/null
        log_message "Cleaned __pycache__ directories"

        # Clean .pyc files
        log_message "Cleaning .pyc files..."
        find "$HOME/dev" -type f -name "*.pyc" -delete 2>/dev/null
        log_message "Cleaned .pyc files"
    fi
}
