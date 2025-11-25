#!/usr/bin/env bash
set -euo pipefail

show_help() {
    cat <<EOF
Usage: $0 [--dry-run] <path-to-repo>

Convert an existing git clone into a blobless partial clone by:
  - Backing up the repo directory
  - Re-cloning using --filter=blob:none from the existing origin
  - Importing all local branches from the backup

Options:
  --dry-run   Show what actions would be taken, but do nothing.

Example:
  $0 ~/dev/posthog/posthog
  $0 --dry-run ~/dev/posthog/posthog
EOF
}

# --------------------------
# Argument parsing
# --------------------------
DRY_RUN=false
REPO_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            if [[ -z "$REPO_DIR" ]]; then
                REPO_DIR="$1"
            else
                echo "ERROR: Unexpected argument: $1" >&2
                echo >&2
                show_help >&2
                exit 1
            fi
            shift
            ;;
    esac
done

if [[ -z "$REPO_DIR" ]]; then
    echo "ERROR: Missing required <path-to-repo> argument." >&2
    echo >&2
    show_help >&2
    exit 1
fi

# Normalize to absolute path
REPO_DIR="$(cd "$(dirname "$REPO_DIR")" && pwd)/$(basename "$REPO_DIR")"

# Simple dry-run helper
run() {
    if $DRY_RUN; then
        printf '[dry-run]'
        for arg in "$@"; do
            printf ' %q' "$arg"
        done
        printf '\n'
    else
        "$@"
    fi
}

echo "=== Converting repo at: ${REPO_DIR} ==="
$DRY_RUN && echo "(dry-run mode enabled)"

# Validate existence
if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "ERROR: '$REPO_DIR' is not a git repository." >&2
    exit 1
fi

cd "$REPO_DIR"

# Check working tree cleanliness
if [[ -n "$(git status --porcelain)" ]]; then
    echo "ERROR: Working tree is not clean. Commit/stash changes first." >&2
    exit 1
fi

# Ensure origin exists
if ! git remote get-url origin >/dev/null 2>&1; then
    echo "ERROR: Repository has no 'origin' remote configured." >&2
    exit 1
fi

ORIGIN_URL="$(git remote get-url origin)"
echo "Detected origin URL: $ORIGIN_URL"

# Capture current branch (may be empty if detached HEAD)
CURRENT_BRANCH="$(git symbolic-ref --quiet --short HEAD || echo "")"
if [[ -n "$CURRENT_BRANCH" ]]; then
    echo "Current branch: $CURRENT_BRANCH"
else
    echo "Current HEAD is detached (no active branch)."
fi

# Capture local branches
echo "Collecting local branches..."
mapfile -t LOCAL_BRANCHES < <(git for-each-ref refs/heads --format='%(refname:short)')

echo "Found ${#LOCAL_BRANCHES[@]} local branches:"
for b in "${LOCAL_BRANCHES[@]}"; do
    echo "  - $b"
done

# Prepare backup path
BACKUP_PARENT="$(dirname "$REPO_DIR")"
BACKUP_NAME="$(basename "$REPO_DIR")-backup-$(date +%Y%m%d-%H%M%S)"
BACKUP_DIR="$BACKUP_PARENT/$BACKUP_NAME"

echo "Backup repo will be moved to: $BACKUP_DIR"

# --------------------------
# Main actions
# --------------------------

echo
echo "=== Step 1: Move existing repo to backup ==="
run mv "$REPO_DIR" "$BACKUP_DIR"

echo
echo "=== Step 2: Clone new blobless repo from origin ==="
run git clone --filter=blob:none "$ORIGIN_URL" "$REPO_DIR"

echo
echo "=== Step 3: Configure partial clone settings (explicit) ==="
run git -C "$REPO_DIR" config remote.origin.promisor true
run git -C "$REPO_DIR" config remote.origin.partialclonefilter blob:none

echo
echo "=== Step 4: Add backup as remote 'old' and fetch ==="
run git -C "$REPO_DIR" remote add old "$BACKUP_DIR"
run git -C "$REPO_DIR" fetch old

echo
echo "=== Step 5: Recreate local branches from backup ==="
for b in "${LOCAL_BRANCHES[@]}"; do
    echo "  - Recreating branch '$b'"

    # Does it exist in backup?
    if ! git -C "$REPO_DIR" show-ref --verify --quiet "refs/remotes/old/$b"; then
        echo "    (skipping: not found in backup)"
        continue
    fi

    run git -C "$REPO_DIR" branch "$b" "old/$b"
done

# Optionally restore the original current branch
if [[ -n "$CURRENT_BRANCH" ]]; then
    echo
    echo "=== Step 6: Restore current branch ==="
    if git -C "$REPO_DIR" show-ref --verify --quiet "refs/heads/$CURRENT_BRANCH"; then
        run git -C "$REPO_DIR" checkout "$CURRENT_BRANCH"
    else
        echo "  (skipping: branch '$CURRENT_BRANCH' was not recreated)"
    fi
fi

echo
echo "=== Conversion complete ==="
echo "New blobless clone: $REPO_DIR"
echo "Backup saved at:    $BACKUP_DIR"

if $DRY_RUN; then
    echo
    echo "Dry run complete — no changes were made."
fi
