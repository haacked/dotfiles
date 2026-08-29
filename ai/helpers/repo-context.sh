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
    REPO_ORG=""
    REPO_REPO=""
    remote_url=$(git remote get-url origin 2>/dev/null) || return 1
    # The (^|[/@]) boundary keeps lookalike hosts (mygithub.com, foo.github.com)
    # from matching while accepting scp, ssh://, and https:// URL shapes.
    if [[ "$remote_url" =~ (^|[/@])github\.com(-[^:/]+)?[:/]([^/]+)/([^/]+)$ ]]; then
        REPO_ORG="${BASH_REMATCH[3]}"
        REPO_REPO="${BASH_REMATCH[4]%.git}"
        return 0
    fi
    return 1
}

# The captures come from a remote URL, which whoever set the remote controls:
# git@github.com:../evil.git parses as an org of "..". Any caller that builds a
# filesystem path out of REPO_ORG/REPO_REPO must pass this first, or the path
# escapes the directory it was meant to stay under. Rejects rather than rewrites,
# so two different repos can never collapse onto one sanitized name.
repo_context_is_path_safe() {
    local component
    for component in "$REPO_ORG" "$REPO_REPO"; do
        case "$component" in
            "" | [.-]* | *[!A-Za-z0-9._-]*) return 1 ;;
        esac
    done
    return 0
}
