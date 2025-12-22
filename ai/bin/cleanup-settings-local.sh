#!/bin/sh

# Cleanup script for ~/.claude/settings.local.json
# Removes duplicates, fixes path typos, and removes entries covered by broader patterns

set -e

export ZSH=$HOME/.dotfiles

# Source helper functions if available
if [ -f "$ZSH/ai/helpers/output.sh" ]; then
    . "$ZSH/ai/helpers/output.sh"
else
    # Fallback if helpers not available
    info() { echo "[INFO] $1"; }
    success() { echo "[OK] $1"; }
    warning() { echo "[WARN] $1"; }
    error() { echo "[ERROR] $1"; }
fi

SETTINGS_FILE="$HOME/.claude/settings.local.json"

if [ ! -f "$SETTINGS_FILE" ]; then
    info "No settings.local.json found - nothing to clean"
    exit 0
fi

if ! command -v jq > /dev/null 2>&1; then
    error "jq is required but not installed"
    exit 1
fi

# Validate JSON first
if ! jq empty "$SETTINGS_FILE" > /dev/null 2>&1; then
    error "settings.local.json contains invalid JSON"
    exit 1
fi

BEFORE_COUNT=$(jq '.permissions.allow | length' "$SETTINGS_FILE" 2>/dev/null || echo "0")
info "Found $BEFORE_COUNT permission entries"

# Create backup
cp "$SETTINGS_FILE" "${SETTINGS_FILE}.bak"
info "Backup created at ${SETTINGS_FILE}.bak"

# Process the settings file:
# 1. Fix double slashes in paths (//Users -> /Users, //Library -> /Library)
# 2. Remove duplicates
# 3. Remove entries covered by broader wildcard patterns
jq '
# Helper function to check if a specific entry is covered by a wildcard pattern
def is_covered_by($wildcards):
    . as $entry |
    any($wildcards[]; . as $pattern |
        # Extract the prefix before :* or before the closing paren
        ($pattern |
            if test(":\\*\\)$") then
                # Pattern like Bash(git commit:*) - extract "Bash(git commit"
                gsub(":\\*\\)$"; "")
            elif test("\\*\\*\\)$") then
                # Pattern like Read(/Users/**) - extract "Read(/Users/"
                gsub("\\*\\*\\)$"; "")
            else
                null
            end
        ) as $prefix |
        if $prefix != null then
            ($entry | startswith($prefix)) and ($entry != $pattern)
        else
            false
        end
    );

# Fix double slashes in paths
def fix_double_slashes:
    gsub("\\(//(?<path>Users|Library|tmp)"; "(/\(.path)");

.permissions.allow |= (
    # Step 1: Fix double slashes
    map(fix_double_slashes) |

    # Step 2: Remove exact duplicates
    unique |

    # Step 3: Identify wildcard patterns (ending in :*) or (**)
    . as $all |
    [$all[] | select(test(":\\*\\)$") or test("\\*\\*\\)$"))] as $wildcards |

    # Step 4: Filter out entries covered by wildcards
    [.[] | select(is_covered_by($wildcards) | not)]
)
' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"

# Validate the result
if ! jq empty "${SETTINGS_FILE}.tmp" > /dev/null 2>&1; then
    error "Generated invalid JSON - restoring backup"
    mv "${SETTINGS_FILE}.bak" "$SETTINGS_FILE"
    rm -f "${SETTINGS_FILE}.tmp"
    exit 1
fi

mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"

AFTER_COUNT=$(jq '.permissions.allow | length' "$SETTINGS_FILE" 2>/dev/null || echo "0")
REMOVED=$((BEFORE_COUNT - AFTER_COUNT))

if [ "$REMOVED" -gt 0 ]; then
    success "Removed $REMOVED redundant entries ($BEFORE_COUNT → $AFTER_COUNT)"
else
    success "No redundant entries found"
fi

# Show what wildcards are protecting the remaining entries
info "Active wildcard patterns:"
jq -r '.permissions.allow[] | select(test(":\\*\\)$") or test("\\*\\*\\)$"))' "$SETTINGS_FILE" | sort -u | head -20 | while read -r pattern; do
    echo "  • $pattern"
done

echo ""
success "Cleanup complete!"
