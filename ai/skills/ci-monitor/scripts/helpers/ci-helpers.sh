#!/usr/bin/env bash
# ci-helpers.sh - Shared constants and utilities for ci-monitor skill
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/helpers/ci-helpers.sh"

# ── Constants ────────────────────────────────────────────────────────────────

CI_POLL_INTERVAL=30   # seconds between polls
CI_TIMEOUT_MINUTES=30 # default overall timeout
CI_MAX_FIX_RETRIES=3  # max fix-push-monitor cycles
CI_LOG_TAIL_LINES=200 # lines of log to keep per failed job

# ── gh CLI wrapper ───────────────────────────────────────────────────────────
# Suppress DEBUG env var that causes gh to emit verbose output

if command -v gh > /dev/null 2>&1; then
    gh() {
        DEBUG= command gh "$@"
    }
fi

# ── Dependency check ────────────────────────────────────────────────────────
# Must be called before ci_json_error since that function depends on jq.
# Uses printf for JSON output so it works even if jq is missing.

ci_require_cmds() {
    local missing=()
    for cmd in "$@"; do
        command -v "${cmd}" > /dev/null 2>&1 || missing+=("${cmd}")
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        local joined
        joined=$(printf '%s, ' "${missing[@]}")
        joined="${joined%, }"
        printf '{"error":"Required commands not found: %s"}\n' "${joined}" >&1
        exit 0
    fi
}

# ── Error helpers ────────────────────────────────────────────────────────────

error() {
    echo -e "\033[31mError: $*\033[0m" >&2
}

# ── Git helpers ──────────────────────────────────────────────────────────────

validate_git_repo() {
    if ! git rev-parse --git-dir > /dev/null 2>&1; then
        error "Not in a git repository"
        return 1
    fi
}

# Extract org and repo from git remote URL
# Returns: "org|repo" on success, "unknown|unknown" on failure
get_git_org_repo() {
    # Try gh CLI first (most reliable)
    if command -v gh > /dev/null 2>&1; then
        local gh_data
        gh_data=$(gh repo view --json owner,name -q '"\(.owner.login)|\(.name)"' 2> /dev/null || echo "")
        if [[ -n "${gh_data}" ]]; then
            local org="${gh_data%|*}"
            local repo="${gh_data#*|}"
            org=$(echo "${org}" | tr '[:upper:]' '[:lower:]')
            repo=$(echo "${repo}" | tr '[:upper:]' '[:lower:]')
            echo "${org}|${repo}"
            return 0
        fi
    fi

    # Fallback: Parse git remote URL
    local remote_url
    remote_url=$(git remote get-url origin 2> /dev/null || echo "")

    if [[ -z "${remote_url}" ]]; then
        echo "unknown|unknown"
        return 0
    fi

    if [[ ${remote_url} =~ ^(https://|git@)github\.com[:/]([a-zA-Z0-9_-]+)/([a-zA-Z0-9._-]+)(\.git)?$ ]]; then
        local org="${BASH_REMATCH[2]}"
        local repo="${BASH_REMATCH[3]}"
        org=$(echo "${org}" | tr '[:upper:]' '[:lower:]')
        repo=$(echo "${repo}" | tr '[:upper:]' '[:lower:]')
        echo "${org}|${repo}"
        return 0
    fi

    echo "unknown|unknown"
}

get_current_branch() {
    git branch --show-current
}

# ── CI-specific helpers ──────────────────────────────────────────────────────

# Build --repo flag array from an org/repo string
# Usage: repo_flag=($(ci_build_repo_flag "$repo_arg"))
# Returns nothing if repo_arg is empty
ci_build_repo_flag() {
    local repo_arg="$1"
    if [[ -n "${repo_arg}" ]]; then
        echo "--repo" "${repo_arg}"
    fi
}

# Get the list of files changed in a PR
# Usage: ci_get_pr_changed_files <pr_number> [<org/repo>]
ci_get_pr_changed_files() {
    local pr_number="$1"
    local repo_arg="${2:-}"
    local repo_flag=()
    if [[ -n "${repo_arg}" ]]; then
        repo_flag=(--repo "${repo_arg}")
    fi
    gh pr diff "${pr_number}" "${repo_flag[@]}" --name-only 2> /dev/null || echo ""
}

# JSON output helper
ci_json_error() {
    local message="$1"
    jq -n --arg msg "${message}" '{"error": $msg}'
}
