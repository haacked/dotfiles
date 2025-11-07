#!/bin/bash
# Docker cleanup module
# Cleans Docker containers, images, networks, volumes, and build cache

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

cleanup_docker() {
    local mode="${1:-conservative}"

    if ! command -v docker >/dev/null 2>&1; then
        log_message "Docker not installed, skipping Docker cleanup"
        return 0
    fi

    log_message "Running Docker cleanup (mode: $mode)..."

    if [ "$mode" = "aggressive" ]; then
        cleanup_docker_aggressive
    else
        cleanup_docker_conservative
    fi
}

cleanup_docker_conservative() {
    # Conservative cleanup: removes stopped containers and dangling images only
    # Does NOT remove images that stopped containers depend on

    # Only clean up stopped/dead containers (not running ones)
    run_cleanup "Docker container cleanup" "docker container prune -f"

    # Only remove dangling images (untagged and not referenced)
    # Does NOT remove images that stopped containers depend on
    run_cleanup "Docker image cleanup (dangling only)" "docker image prune -f"

    # Clean up unused networks (safe - doesn't affect running containers)
    run_cleanup "Docker network cleanup" "docker network prune -f"

    # Clean build cache (safe - can always rebuild)
    run_cleanup "Docker build cache cleanup" "docker builder prune -f"

    # Only prune truly orphaned volumes (not associated with any container)
    # This is safe because it won't remove volumes from stopped containers
    log_message "Docker volume cleanup (orphaned volumes only)"
    local orphaned_volumes
    orphaned_volumes=$(docker volume ls -qf dangling=true)
    if [ -n "$orphaned_volumes" ]; then
        run_cleanup "Docker orphaned volume cleanup" "docker volume prune -f"
    else
        log_message "No orphaned volumes to clean up"
    fi
}

cleanup_docker_aggressive() {
    # Aggressive cleanup: removes ALL unused Docker resources
    # WARNING: This will remove stopped containers and their images/volumes
    log_message "⚠️  Running AGGRESSIVE Docker cleanup - this will remove ALL unused resources"

    run_cleanup "Docker system prune (aggressive)" "docker system prune -a -f --volumes"

    log_message "Docker aggressive cleanup complete"
}
