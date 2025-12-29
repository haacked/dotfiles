#!/bin/bash
# Rust cleanup module
# Cleans Rust target directories and cargo cache

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_rust() {
    local mode="${1:-conservative}"

    if ! command -v cargo >/dev/null 2>&1; then
        log_message "Rust not installed, skipping Rust cleanup"
        return 0
    fi

    log_message "Running Rust cleanup (mode: $mode)..."

    if [ "$mode" = "aggressive" ]; then
        cleanup_rust_aggressive
    else
        cleanup_rust_conservative
    fi
}

cleanup_rust_conservative() {
    # Conservative cleanup: runs cargo clean in all projects + normal cargo cache cleanup
    log_message "Running cargo clean in Rust projects..."
    local project_count=0

    # Find all Cargo.toml files (workspace roots) and run cargo clean
    find "$HOME/dev" -name "Cargo.toml" -type f 2>/dev/null | while read -r cargo_file; do
        local project_dir
        project_dir=$(dirname "$cargo_file")
        local target_dir="$project_dir/target"

        # Only process if this is a workspace root (has target directory) or standalone project
        if [ -d "$target_dir" ]; then
            local size_before
            size_before=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
            log_message "  Cleaning: $project_dir ($size_before)"

            # Run cargo clean from the project directory
            (cd "$project_dir" && cargo clean 2>/dev/null) || true

            if [ -d "$target_dir" ]; then
                local size_after
                size_after=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
                log_message "    After: $size_after"
            else
                log_message "    Removed target directory"
            fi
            project_count=$((project_count + 1))
        fi
    done

    log_message "  Cleaned $project_count Rust projects"

    # Clean cargo cache (registry and git checkouts)
    if command -v cargo-cache >/dev/null 2>&1; then
        run_cleanup "Cargo cache cleanup (via cargo-cache)" "cargo-cache --autoclean"
    else
        log_message "Cargo cache cleanup (manual - install cargo-cache for better results)"

        # Remove old registry cache (keep last 30 days)
        if [ -d "$HOME/.cargo/registry/cache" ]; then
            find "$HOME/.cargo/registry/cache" -type f -name "*.crate" -mtime +30 -delete 2>/dev/null
        fi

        # Remove git checkouts older than 30 days
        if [ -d "$HOME/.cargo/git/checkouts" ]; then
            find "$HOME/.cargo/git/checkouts" -type d -mtime +30 -maxdepth 2 -exec rm -rf {} + 2>/dev/null
        fi
    fi
}

cleanup_rust_aggressive() {
    # Aggressive cleanup: everything in conservative + rustup cleanup + old toolchain removal
    log_message "Running aggressive Rust cleanup..."

    local space_before
    space_before=$(df -k / | tail -1 | awk '{print $3}')

    # First, do everything conservative does
    cleanup_rust_conservative

    # Aggressive cargo cache cleanup
    if command -v cargo-cache >/dev/null 2>&1; then
        run_cleanup "Cargo cache (aggressive)" "cargo-cache --autoclean-expensive && cargo-cache --remove-dir git-db,git-repos"
    else
        log_message "cargo-cache not installed - install with: cargo install cargo-cache"
        log_message "Falling back to manual cleanup..."

        # Remove all git checkouts
        if [ -d ~/.cargo/git/checkouts ]; then
            log_message "  Removing git checkouts..."
            rm -rf ~/.cargo/git/checkouts/*
        fi

        # Remove all registry cache
        if [ -d ~/.cargo/registry/cache ]; then
            log_message "  Cleaning registry cache..."
            rm -rf ~/.cargo/registry/cache/*
        fi
    fi

    # Clean rustup temporary files
    log_message "Cleaning rustup temp files..."
    if [ -d ~/.rustup/tmp ]; then
        rm -rf ~/.rustup/tmp/*
    fi

    if [ -d ~/.rustup/downloads ]; then
        rm -rf ~/.rustup/downloads/*
    fi

    # Remove old toolchains (keep only stable, beta, and nightly)
    log_message "Checking for old toolchains..."
    rustup toolchain list | grep -v -E "(stable|beta|nightly)" | while read -r toolchain; do
        log_message "  Removing old toolchain: $toolchain"
        rustup toolchain uninstall "$toolchain"
    done

    local space_after
    space_after=$(df -k / | tail -1 | awk '{print $3}')
    local total_saved=$(( (space_before - space_after) / 1024 ))
    log_message "Rust aggressive cleanup saved: ${total_saved}MB"
}
