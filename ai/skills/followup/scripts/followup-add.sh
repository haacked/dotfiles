#!/usr/bin/env bash
# Add a follow-up item to the central followups file.
#
# Usage: followup-add.sh <text...>
#
# Derives the date, org/repo, and branch from the current directory's git
# state, inserts the item at the top of the "## Open" section (newest first),
# creates the file from a skeleton when missing, and prints a capture summary.

set -euo pipefail

export FOLLOWUPS_FILE="${FOLLOWUPS_FILE:-$HOME/dev/haacked/notes/PostHog/Followups.md}"

if [[ $# -lt 1 ]]; then
    echo "Usage: followup-add.sh <text>" >&2
    exit 1
fi

text="$*"

# Derive the [org/repo · branch] context; outside a git repo, record [no-repo].
context="no-repo"
repo=""
if git rev-parse --git-dir > /dev/null 2>&1; then
    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        repo="${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
        branch=$(git branch --show-current 2>/dev/null || echo "")
        if [[ -n "$branch" ]]; then
            context="${repo} · ${branch}"
        else
            context="$repo"
        fi
    fi
fi

line="- [ ] $(date +%Y-%m-%d) · [${context}] ${text}"

if [[ ! -f "$FOLLOWUPS_FILE" ]]; then
    mkdir -p "$(dirname "$FOLLOWUPS_FILE")"
    cat > "$FOLLOWUPS_FILE" <<'EOF'
# Followups

Captured mid-session via /followup. Open items surface at session start and in /standup. Newest first. `- [ ]` open, `- [x]` done, `- [-]` dropped.

## Open

## Archive
EOF
fi

if ! grep -q '^## Open$' "$FOLLOWUPS_FILE"; then
    echo "Error: no '## Open' section in $FOLLOWUPS_FILE" >&2
    exit 1
fi

# Insert at the top of the Open section, keeping the item list contiguous and
# the blank lines around headings intact (including when the section is empty).
# The text rides in via ENVIRON because awk -v and sed both mangle backslashes.
tmp=$(mktemp)
FOLLOWUP_LINE="$line" awk '
    {
        print
        if (!done && $0 == "## Open") {
            print ""
            print ENVIRON["FOLLOWUP_LINE"]
            done = 1
            while ((getline nxt) > 0) {
                if (nxt == "") continue
                if (nxt ~ /^#/) print ""
                print nxt
                break
            }
        }
    }
' "$FOLLOWUPS_FILE" > "$tmp"
mv "$tmp" "$FOLLOWUPS_FILE"

open_helper="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/followup-open.sh"
open_total=$("$open_helper" | grep -c . || true)
echo "Captured: ${line}"
if [[ -n "$repo" ]]; then
    open_repo=$("$open_helper" "$repo" | grep -c . || true)
    echo "Open for ${repo}: ${open_repo} · total open: ${open_total}"
else
    echo "Total open: ${open_total}"
fi
