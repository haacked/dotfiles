#!/usr/bin/env bash
# Tests for support-parse-ticket.sh (argument normalization) and
# support-find-ticket.sh (week search, migrated-ticket fallback).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PARSE="${SCRIPT_DIR}/../support-parse-ticket.sh"
FIND="${SCRIPT_DIR}/../support-find-ticket.sh"
NOTES_DIR="${SCRIPT_DIR}/../support-notes-dir.sh"
WEEK_DIR="${SCRIPT_DIR}/../support-week-dir.sh"

passes=0
failures=0

check() { # desc actual expected
    if [[ "$2" == "$3" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $1"
        echo "  expected [$3], got [$2]"
        failures=$((failures + 1))
    fi
}

# The scripts read $HOME/dev/ai/support. Point HOME at a throwaway tree before any
# of them run, so nothing here can reach the real support notes.
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export HOME="$T"
SUPPORT="$HOME/dev/ai/support"

# --- support-find-ticket.sh: no support tree yet ---

# Checked before the fixtures exist: a first-ever ticket must report new, not crash
# on the unmatched week glob.
check "missing support base yields new" "$("$FIND" posthog 3064 | cut -f1)" "new"

# --- fixtures ---

mkdir -p "$SUPPORT/2026-08-10/posthog-3064" \
    "$SUPPORT/2026-09-07/posthog-3064" \
    "$SUPPORT/2026-08-10/github-77"

# Migrated ticket: notes filed under the in-app number, old Zendesk number in front matter.
cat > "$SUPPORT/2026-08-10/posthog-3064/notes.md" <<'EOF'
# Ticket posthog-3064

**Ticket URL**: https://us.posthog.com/project/2/support/tickets/3064
**Linked Zendesk**: zendesk/40875
**Started**: 2026-08-10
EOF
printf '# Ticket posthog-3064 (later week)\n' > "$SUPPORT/2026-09-07/posthog-3064/notes.md"

# A body mention of another ticket must not pass for that ticket's identity.
cat > "$SUPPORT/2026-08-10/github-77/notes.md" <<'EOF'
# Ticket github-77

**Ticket URL**: https://github.com/PostHog/posthog/issues/77
Same root cause as zendesk/55555, which we closed last month.
EOF

# --- support-parse-ticket.sh: argument normalization ---

parsed=$("$PARSE" posthog 3064)
check "type from args" "$(cut -f1 <<< "$parsed")" "posthog"
check "number from args" "$(cut -f2 <<< "$parsed")" "3064"

parsed=$("$PARSE" 'https://us.posthog.com/project/2/support/tickets/3064')
check "in-app url type" "$(cut -f1 <<< "$parsed")" "posthog"
check "in-app url number" "$(cut -f2 <<< "$parsed")" "3064"

parsed=$("$PARSE" 'https://us.posthog.com/project/2/support/tickets/3064?tab=notes#reply')
check "query string and fragment ignored" "$(cut -f2 <<< "$parsed")" "3064"

# The Zendesk host contains "posthoghelp", so this must not fall into the in-app branch.
parsed=$("$PARSE" 'https://posthoghelp.zendesk.com/agent/tickets/40875')
check "zendesk url type" "$(cut -f1 <<< "$parsed")" "zendesk"
check "zendesk url number" "$(cut -f2 <<< "$parsed")" "40875"

parsed=$("$PARSE" 'https://github.com/PostHog/posthog/issues/77')
check "github url type" "$(cut -f1 <<< "$parsed")" "github"
check "github url number" "$(cut -f2 <<< "$parsed")" "77"

parsed=$("$PARSE" 'https://eu.posthog.com/project/2/support/tickets/3064')
check "eu cloud host accepted" "$(cut -f1 <<< "$parsed")" "posthog"

parsed=$("$PARSE" 'us.posthog.com/project/2/support/tickets/3064')
check "schemeless url accepted" "$(cut -f2 <<< "$parsed")" "3064"

# The host is anchored, so a look-alike domain must not pass for the real one.
check "lookalike host rejected" "$("$PARSE" 'https://evilposthog.com/project/2/support/tickets/99' 2>&1 | grep -c 'Error' || true)" "1"
check "ticket path inside a query string rejected" "$("$PARSE" 'https://attacker.example/x?ref=posthog.com/project/2/support/tickets/999' 2>&1 | grep -c 'Error' || true)" "1"

check "github pull url rejected" "$("$PARSE" 'https://github.com/PostHog/posthog/pull/77' 2>&1 | grep -c 'Error' || true)" "1"
check "bare number rejected" "$("$PARSE" 3064 2>&1 | grep -c 'Error' || true)" "1"
check "unexpanded ph shorthand rejected" "$("$PARSE" ph 3064 2>&1 | grep -c 'Error' || true)" "1"
check "non-numeric number rejected" "$("$PARSE" posthog abc 2>&1 | grep -c 'Error' || true)" "1"
# The usage contract is one URL or a type plus a number, so a stray third token is a
# mistake worth surfacing rather than dropping.
check "extra trailing argument rejected" "$("$PARSE" zendesk 40875 extra 2>&1 | grep -c 'Expected arguments' || true)" "1"
check "no args rejected" "$("$PARSE" 2>&1 | grep -c 'Expected arguments' || true)" "1"
check "find propagates a bad type" "$("$FIND" ph 3064 2>&1 | grep -c 'Error' || true)" "1"

# --- support-find-ticket.sh: week search ---

result=$("$FIND" posthog 3064)
check "existing ticket found" "$(cut -f1 <<< "$result")" "found"
check "newest week wins" "$(cut -f2 <<< "$result")" "$SUPPORT/2026-09-07/posthog-3064"

result=$("$FIND" zendesk 90001)
check "unknown ticket is new" "$(cut -f1 <<< "$result")" "new"
check "new path is this week" "$(cut -f2 <<< "$result")" "$("$WEEK_DIR")/zendesk-90001"

# --- support-find-ticket.sh: migrated-ticket fallback ---

result=$("$FIND" zendesk 40875)
check "migrated zendesk number reaches the in-app notes" "$(cut -f2 <<< "$result")" "$SUPPORT/2026-08-10/posthog-3064"

# A shorter number must not match a longer one on the same line.
check "zendesk 4087 does not match zendesk/40875" "$("$FIND" zendesk 4087 | cut -f1)" "new"
# A mention in the body is not the Linked Zendesk line.
check "body mention is not an identity" "$("$FIND" zendesk 55555 | cut -f1)" "new"
# Only zendesk lookups consult the fallback.
check "github lookup skips the linked fallback" "$("$FIND" github 40875 | cut -f1)" "new"

# --- support-notes-dir.sh ---

check "url resolves to a notes dir" "$("$NOTES_DIR" 'https://us.posthog.com/project/2/support/tickets/3064')" "$("$WEEK_DIR")/posthog-3064"

# --- precedence: post-migration notes outrank a stale zendesk-{n} directory ---
# Staged last: it changes what a zendesk 40875 lookup has to choose between.
# Resuming on pre-migration notes would silently drop everything since the migration.

mkdir -p "$SUPPORT/2026-07-06/zendesk-40875"
check "linked in-app notes beat a stale zendesk directory" "$("$FIND" zendesk 40875 | cut -f2)" "$SUPPORT/2026-08-10/posthog-3064"

# A zendesk ticket that was never migrated still resolves to its own directory.
mkdir -p "$SUPPORT/2026-07-06/zendesk-51000"
check "unmigrated zendesk ticket uses its own directory" "$("$FIND" zendesk 51000 | cut -f2)" "$SUPPORT/2026-07-06/zendesk-51000"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
