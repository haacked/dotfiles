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
    # Conservative cleanup: removes old artifacts but keeps recent builds
    log_message "Finding Rust target directories..."

    find "$HOME/dev" -type d -name target 2>/dev/null | while read -r target_dir; do
        if [ -d "$target_dir" ]; then
            size_before=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
            log_message "Found target directory ($size_before): $target_dir"

            # Remove incremental compilation artifacts older than 7 days
            find "$target_dir" -type d -name incremental -exec find {} -type d -mtime +7 -exec rm -rf {} + 2>/dev/null \;

            # Remove debug builds older than 14 days
            find "$target_dir/debug" -type f -mtime +14 -delete 2>/dev/null

            # Remove test artifacts older than 14 days
            find "$target_dir" -type d -name ".fingerprint" -exec find {} -type f -mtime +14 -delete 2>/dev/null \;

            size_after=$(du -sh "$target_dir" 2>/dev/null | cut -f1)
            log_message "Cleaned target directory: $target_dir ($size_before → $size_after)"
        fi
    done

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
    # Aggressive cleanup: removes almost all artifacts except release builds
    log_message "Running aggressive Rust cleanup..."

    local space_before
    space_before=$(df -k / | tail -1 | awk '{print $3}')

    # Clean all target directories in dev folder
    log_message "Cleaning target directories in ~/dev..."
    local target_count=0

    find "$HOME/dev" -type d -name target 2>/dev/null | while read -r target_dir; do
        if [ -d "$target_dir" ]; then
            local size_before
            size_before=$(du -sk "$target_dir" 2>/dev/null | cut -f1)
            log_message "  Cleaning: $target_dir ($(du -sh "$target_dir" 2>/dev/null | cut -f1))"

            # Keep only release artifacts, remove everything else
            if [ -d "$target_dir/release" ]; then
                find "$target_dir" -mindepth 1 -maxdepth 1 ! -name release -exec rm -rf {} + 2>/dev/null
            else
                # No release build, clean everything
                rm -rf "$target_dir"/* 2>/dev/null
            fi

            local size_after
            size_after=$(du -sk "$target_dir" 2>/dev/null | cut -f1 || echo 0)
            local saved=$((size_before - size_after))
            log_message "    Saved: $((saved / 1024))MB"
            target_count=$((target_count + 1))
        fi
    done

    log_message "  Cleaned $target_count target directories"

    # Clean cargo cache aggressively
    if command -v cargo-cache >/dev/null 2>&1; then
        run_cleanup "Cargo cache (aggressive)" "cargo-cache --autoclean && cargo-cache --autoclean-expensive && cargo-cache --remove-dir git-db,git-repos"
    else
        log_message "  ⚠️  cargo-cache not installed. Install with: cargo install cargo-cache"
        log_message "  Falling back to manual cleanup..."

        # Remove old git checkouts
        if [ -d ~/.cargo/git/checkouts ]; then
            log_message "  Removing git checkouts..."
            rm -rf ~/.cargo/git/checkouts/*
        fi

        # Remove old registry cache
        if [ -d ~/.cargo/registry/cache ]; then
            log_message "  Cleaning registry cache..."
            find ~/.cargo/registry/cache -name "*.crate" -mtime +7 -delete 2>/dev/null
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
