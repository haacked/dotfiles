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
SHARED_SETTINGS_FILE="$HOME/.claude/settings.json"

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

# Extract wildcards from shared settings.json (if it exists)
SHARED_WILDCARDS="[]"
if [ -f "$SHARED_SETTINGS_FILE" ]; then
    SHARED_WILDCARDS=$(jq '[.permissions.allow[]? | select(test(":\\*\\)$") or test("\\*\\*\\)$") or test("\\(\\*\\)$"))]' "$SHARED_SETTINGS_FILE" 2>/dev/null || echo "[]")
fi

# Process the settings file:
# 1. Fix double slashes in paths (//Users -> /Users, //Library -> /Library)
# 2. Remove duplicates
# 3. Remove entries covered by broader wildcard patterns (from both local and shared settings)
jq --argjson shared_wildcards "$SHARED_WILDCARDS" '
# Helper function to check if a specific entry is covered by a wildcard pattern
def is_covered_by($wildcards):
    . as $entry |
    any($wildcards[]; . as $pattern |
        # Extract the prefix before the wildcard
        ($pattern |
            if test("^Bash\\(") and test(":\\*\\)$") then
                # Bash pattern like Bash(git commit:*) or Bash(tail:*)
                # Replace :*) with space to ensure word boundary matching
                # This prevents Bash(tail:*) from matching Bash(tailscale:*)
                gsub(":\\*\\)$"; " ")
            elif test(":\\*\\)$") then
                # Non-Bash pattern like WebFetch(domain:*) - keep the colon
                gsub("\\*\\)$"; "")
            elif test("\\*\\*\\)$") then
                # Pattern like Read(/Users/**) - extract "Read(/Users/"
                gsub("\\*\\*\\)$"; "")
            elif test("\\(\\*\\)$") then
                # Pattern like Fetch(*)
                gsub("\\*\\)$"; "")
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

    # Step 3: Identify wildcard patterns from local file
    . as $all |
    [$all[] | select(test(":\\*\\)$") or test("\\*\\*\\)$") or test("\\(\\*\\)$"))] as $local_wildcards |

    # Step 4: Combine local and shared wildcards
    ($local_wildcards + $shared_wildcards) as $all_wildcards |

    # Step 5: Filter out entries covered by any wildcards
    [.[] | select(is_covered_by($all_wildcards) | not)]
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
