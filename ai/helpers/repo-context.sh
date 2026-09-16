#!/usr/bin/env bash
# Name the GitHub org, repo, and branch of the current directory's checkout.
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

# Name the branch this checkout's work belongs to, and print it.
#
# An agent harness (PostHog Desktop, cloud runners) checks the PR head out
# detached, where `git branch --show-current` is empty. RAN_BRANCH lets a caller
# that already resolved the PR skip the last tier. Pass "network" to allow that
# tier, which asks GitHub which PR has HEAD as its head commit; a caller that
# must never touch the network omits the argument and gets the first two tiers.
#
# Usage: resolve_branch_name [network]
# Returns 1 when no tier answers.
resolve_branch_name() {
    local branch head_sha
    branch=$(git branch --show-current 2> /dev/null) || branch=""
    [ -n "$branch" ] || branch="${RAN_BRANCH:-}"
    if [ -z "$branch" ] && [ "${1:-}" = "network" ]; then
        head_sha=$(git rev-parse HEAD 2> /dev/null) || head_sha=""
        if [ -n "$head_sha" ]; then
            # The endpoint also lists PRs this commit merged into, so a detached
            # main would otherwise resolve to whatever landed last. Only an exact
            # head.sha match is this commit's own PR.
            branch=$(env GIT_PR_HEAD_SHA="$head_sha" GH_PAGER= \
                gh api "repos/{owner}/{repo}/commits/${head_sha}/pulls" \
                --jq '[.[] | select(.head.sha == $ENV.GIT_PR_HEAD_SHA)] | sort_by(.state != "open") | .[0].head.ref' \
                2> /dev/null) || branch=""
            if [ "$branch" = "null" ]; then
                branch=""
            fi
        fi
    fi
    [ -n "$branch" ] || return 1
    printf '%s\n' "$branch"
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
