#!/bin/bash
# Node.js cleanup module
# Cleans npm, yarn, and pnpm caches

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_node() {
    local mode="${1:-conservative}"

    log_message "Running Node.js cleanup (mode: $mode)..."

    # Yarn cache cleanup
    if command -v yarn >/dev/null 2>&1; then
        run_cleanup "Yarn cache cleanup" "yarn cache clean"
    fi

    # pnpm store cleanup
    if command -v pnpm >/dev/null 2>&1; then
        run_cleanup "pnpm store cleanup" "pnpm store prune"
    fi

    # npm cache cleanup
    if command -v npm >/dev/null 2>&1; then
        run_cleanup "npm cache cleanup" "npm cache clean --force"
    fi

    # Aggressive mode: also clean node_modules in old projects
    if [ "$mode" = "aggressive" ]; then
        log_message "Aggressive mode: looking for old node_modules directories..."

        # Find node_modules older than 90 days
        find "$HOME/dev" -type d -name node_modules -mtime +90 2>/dev/null | while read -r nm_dir; do
            local size
            size=$(du -sh "$nm_dir" 2>/dev/null | cut -f1)
            log_message "  Found old node_modules: $nm_dir ($size)"
            log_message "  Skipping automatic deletion - run manually if needed: rm -rf '$nm_dir'"
        done
    fi
}
