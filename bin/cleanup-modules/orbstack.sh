#!/bin/bash
# OrbStack cleanup module
# Removes data images that OrbStack set aside as corrupt

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_orbstack() {
    local mode="${1:-conservative}" data_dir image size

    for data_dir in "$HOME/Library/Group Containers/"*.dev.orbstack/data; do
        [ -d "$data_dir" ] || continue
        log_message "Running OrbStack cleanup..."

        # OrbStack renames a data image it cannot repair to *.corrupt and starts
        # a new data.img.raw. Without the new image, the .corrupt one may be the
        # only copy of the Docker data.
        if [ ! -f "$data_dir/data.img.raw" ]; then
            log_message "No live OrbStack data image in $data_dir, keeping corrupt images"
            continue
        fi

        for image in "$data_dir"/*.corrupt; do
            [ -f "$image" ] || continue
            size=$(du -sh "$image" 2>/dev/null | cut -f1)
            # The new image starts empty, so the corrupt one may hold the only
            # copy of older containers and volumes.
            if [ "$mode" = "aggressive" ]; then
                run_cleanup "Remove corrupt OrbStack data image $image ($size)" "rm -f $(printf '%q' "$image")"
            else
                log_message "  Corrupt OrbStack data image (--aggressive removes it): $image ($size)"
            fi
        done
    done
    return 0
}
