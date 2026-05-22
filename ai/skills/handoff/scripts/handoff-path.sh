#!/usr/bin/env bash
# Resolve where the handoff doc lives for the current working directory.
#
# Output (tab-separated, single line):
#   <status>\t<path>\t<scope>
#
# status: existing | new
# scope : repo:<org>/<repo> | dir:<sanitized-cwd>
#
# Inside a git repo: <repo-root>/.notes/handoff.md
# Outside a git repo: ~/.claude/handoff/dir-<hash>.md

set -euo pipefail

if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    path="${git_root}/.notes/handoff.md"

    remote_url=$(git remote get-url origin 2>/dev/null || echo "")
    if [[ "$remote_url" =~ github\.com[:/]([^/]+)/([^/.]+)(\.git)?$ ]]; then
        scope="repo:${BASH_REMATCH[1]}/${BASH_REMATCH[2]}"
    else
        scope="repo:$(basename "$git_root")"
    fi
else
    cwd=$(pwd)
    hash=$(printf '%s' "$cwd" | shasum -a 1 | cut -c1-12)
    path="${HOME}/.claude/handoff/dir-${hash}.md"
    scope="dir:${cwd}"
fi

if [[ -f "$path" ]]; then
    status="existing"
else
    status="new"
fi

printf '%s\t%s\t%s\n' "$status" "$path" "$scope"
