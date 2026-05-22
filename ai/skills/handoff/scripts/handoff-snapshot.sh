#!/usr/bin/env bash
# Capture a snapshot of the current git state for inclusion in a handoff doc.
# Outputs a markdown fenced block to stdout. Safe to run outside a git repo.

set -euo pipefail

ts=$(date '+%Y-%m-%d %H:%M %Z')

if ! git rev-parse --git-dir > /dev/null 2>&1; then
    cat <<EOF
\`\`\`
timestamp: ${ts}
cwd:       $(pwd)
git:       (not a git repo)
\`\`\`
EOF
    exit 0
fi

branch=$(git branch --show-current 2>/dev/null || echo "(detached)")
head_hash=$(git rev-parse --short HEAD 2>/dev/null || echo "(no commits)")
head_subject=$(git log -1 --pretty=%s 2>/dev/null || echo "")
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null || echo "(no upstream)")
ahead_behind=$(git rev-list --left-right --count "@{upstream}...HEAD" 2>/dev/null || echo "")

dirty=$(git status --porcelain=v1 2>/dev/null || true)
if [[ -z "$dirty" ]]; then
    dirty_block="(clean working tree)"
else
    dirty_block="$dirty"
fi

cat <<EOF
\`\`\`
timestamp: ${ts}
branch:    ${branch}
head:      ${head_hash} ${head_subject}
upstream:  ${upstream}${ahead_behind:+ (behind/ahead: ${ahead_behind})}
\`\`\`

**Working tree:**

\`\`\`
${dirty_block}
\`\`\`
EOF
