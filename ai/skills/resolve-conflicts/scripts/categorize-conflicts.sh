#!/bin/bash
# Categorize conflicted files by resolution strategy.
#
# Usage: categorize-conflicts.sh
#
# Output format (tab-separated, one per line):
#   <category>\t<file_path>
#
# Categories:
#   lockfile   - Package lock files (accept theirs, regenerate later)
#   migration  - Database migration files (flag for user)
#   mergiraf   - Files in languages mergiraf can structurally merge
#   other      - Everything else (AI-assisted resolution)

set -euo pipefail

# File extensions mergiraf supports for structural merging.
mergiraf_extensions=(
    java properties kt rs go
    js jsx mjs json yml yaml toml
    html htm xhtml xml
    c h cc hh cpp hpp cxx hxx "c++" "h++" mpp cppm ixx tcc
    cs dart dts scala sbt ts tsx
    py php phtml php3 php4 php5 phps phpt
    sol lua rb ex exs nix
)

is_mergiraf_supported() {
    local file="$1"
    local ext="${file##*.}"
    local name="${file##*/}"

    # mergiraf also handles these files by name.
    case "$name" in
        go.mod|go.sum|go.work.sum) return 0 ;;
    esac

    for supported in "${mergiraf_extensions[@]}"; do
        if [[ "$ext" == "$supported" ]]; then
            return 0
        fi
    done
    return 1
}

is_lockfile() {
    local name="${1##*/}"
    case "$name" in
        package-lock.json|yarn.lock|pnpm-lock.yaml|Cargo.lock|poetry.lock|Gemfile.lock|composer.lock|bun.lockb|bun.lock)
            return 0
            ;;
    esac
    return 1
}

is_migration() {
    local file="$1"
    # Common migration path patterns across frameworks. Paths from git are
    # relative to the repo root, so they may start with the directory name
    # directly (e.g., "migrations/...") or be nested (e.g., "app/migrations/...").
    case "$file" in
        migrations/*|*/migrations/*) return 0 ;;
        alembic/*|*/alembic/*) return 0 ;;
        db/migrate/*|*/db/migrate/*) return 0 ;;
        migrate/*|*/migrate/*) return 0 ;;
    esac
    return 1
}

# Get the list of conflicted (unmerged) files.
conflicted_files=$(git diff --name-only --diff-filter=U 2>/dev/null)

if [[ -z "$conflicted_files" ]]; then
    exit 0
fi

while IFS= read -r file; do
    if is_lockfile "$file"; then
        printf "lockfile\t%s\n" "$file"
    elif is_migration "$file"; then
        printf "migration\t%s\n" "$file"
    elif is_mergiraf_supported "$file"; then
        printf "mergiraf\t%s\n" "$file"
    else
        printf "other\t%s\n" "$file"
    fi
done <<< "$conflicted_files"
