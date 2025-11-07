#!/bin/bash
# Xcode cleanup module
# Cleans Xcode simulators, derived data, and old versions

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_xcode() {
    local mode="${1:-conservative}"

    if ! command -v xcrun >/dev/null 2>&1; then
        log_message "Xcode not installed, skipping Xcode cleanup"
        return 0
    fi

    log_message "Running Xcode cleanup (mode: $mode)..."

    # Xcode simulator cleanup (always safe)
    run_cleanup "Xcode simulator cleanup" "xcrun simctl delete unavailable"
    run_cleanup "Remove unused simulator runtimes" "xcrun simctl runtime delete unavailable"

    # Xcode derived data cleanup (always safe - can be regenerated)
    if [ -d "$HOME/Library/Developer/Xcode/DerivedData" ]; then
        run_cleanup "Xcode derived data cleanup" "rm -rf ~/Library/Developer/Xcode/DerivedData/*"
    fi

    # Aggressive mode: remove old Xcode versions
    if [ "$mode" = "aggressive" ]; then
        if [ -d "/Applications" ]; then
            local xcode_count
            xcode_count=$(find /Applications -maxdepth 1 -name "Xcode*.app" 2>/dev/null | wc -l)
            if [ "$xcode_count" -gt 1 ]; then
                log_message "Multiple Xcode versions found. Keeping latest version..."
                # Find all Xcode versions except the newest one
                local old_xcodes
                old_xcodes=$(find /Applications -maxdepth 1 -name "Xcode*.app" -print0 2>/dev/null | xargs -0 ls -td | tail -n +2)
                if [ -n "$old_xcodes" ]; then
                    echo "$old_xcodes" | while read -r xcode_path; do
                        log_message "  Would remove: $xcode_path"
                        log_message "  Run manually if needed: sudo rm -rf '$xcode_path'"
                    done
                fi
            fi
        fi
    fi
}
