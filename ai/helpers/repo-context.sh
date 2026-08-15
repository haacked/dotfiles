#!/usr/bin/env bash
# Derive the GitHub org/repo of the current directory's origin remote.
#
# Usage: source repo-context.sh, then: derive_org_repo || <no-github fallback>
#
# Sets REPO_ORG and REPO_REPO on success (return 0); returns 1 when there is no
# repo, no origin, or the URL isn't GitHub-shaped. Handles SSH host aliases
# (git@github.com-work:Org/repo.git) and repo names containing dots
# (PostHog/posthog.com); a trailing .git is stripped. Hosts that merely start
# with github.com (github.company.com) do not match.

# shellcheck disable=SC2034  # REPO_ORG/REPO_REPO are consumed by callers.
derive_org_repo() {
    local remote_url
    remote_url=$(git remote get-url origin 2>/dev/null) || return 1
    if [[ "$remote_url" =~ github\.com(-[^:/]+)?[:/]([^/]+)/([^/]+)$ ]]; then
        REPO_ORG="${BASH_REMATCH[2]}"
        REPO_REPO="${BASH_REMATCH[3]%.git}"
        return 0
    fi
    return 1
}
