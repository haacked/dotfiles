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
# Outside a git repo: ~/.agents/handoff/dir-<hash>.md

set -euo pipefail

# shellcheck source=/dev/null
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../../helpers/repo-context.sh"

if git_root=$(git rev-parse --show-toplevel 2>/dev/null); then
    path="${git_root}/.notes/handoff.md"

    if derive_org_repo; then
        scope="repo:${REPO_ORG}/${REPO_REPO}"
    else
        scope="repo:$(basename "$git_root")"
    fi
else
    cwd=$(pwd)
    hash=$(printf '%s' "$cwd" | shasum -a 1 | cut -c1-12)
    path="${HOME}/.agents/handoff/dir-${hash}.md"
    scope="dir:${cwd}"
fi

if [[ -f "$path" ]]; then
    status="existing"
else
    status="new"
fi

printf '%s\t%s\t%s\n' "$status" "$path" "$scope"
