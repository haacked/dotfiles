#!/usr/bin/env bash
# ci-helpers.sh - Shared constants and utilities for ci-monitor skill
#
# Usage:
#   source "$(dirname "${BASH_SOURCE[0]}")/helpers/ci-helpers.sh"

# ── Constants ────────────────────────────────────────────────────────────────

CI_POLL_INTERVAL=30      # seconds between polls
CI_TIMEOUT_MINUTES=30    # default overall timeout
CI_MAX_FIX_RETRIES=3     # max fix-push-monitor cycles
CI_LOG_TAIL_LINES=80     # lines of log to keep per failed job
CI_MAX_AUTO_REQUEUES=2   # max auto /trunk merge re-submissions per head SHA

# The Trunk merge queue's GitHub App identity. GitHub forbids "[" and "]" in
# human usernames, so this login cannot be registered by a person; comments
# from it are genuinely Trunk's. Their prose is still only ever read as data.
CI_TRUNK_BOT="trunk-io[bot]"

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

# ── CI-specific helpers ──────────────────────────────────────────────────────

# Build a --repo flag array from an org/repo string.
# Usage: local repo_flag=(); ci_repo_flag repo_flag "$repo_arg"
ci_repo_flag() {
    local -n _arr=$1
    local repo_arg="$2"
    _arr=()
    if [[ -n "${repo_arg}" ]]; then
        _arr=(--repo "${repo_arg}")
    fi
}

# Resolve an org/repo argument, falling back to the current directory's repo.
# Prints nothing when neither resolves; callers fail closed on empty.
# Usage: repo_nwo=$(ci_resolve_repo_nwo "$repo_arg")
ci_resolve_repo_nwo() {
    local repo_nwo="$1"
    if [[ -z "${repo_nwo}" ]]; then
        repo_nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || echo "")
    fi
    printf '%s' "${repo_nwo}"
}

# Fetch every issue comment on a PR as one slurped JSON array of pages.
# Paginated in full rather than reading one page: a bot's status comment is
# often the PR's *oldest* (posted on open, edited in place), so fetching only
# the newest page would systematically miss it. gh api writes HTTP error
# bodies to stdout, so callers must put their `||` fallback outside the
# command substitution: comments=$(ci_fetch_pr_comments <pr> <org/repo>) || comments="[]"
ci_fetch_pr_comments() {
    gh api --paginate --slurp "repos/${2}/issues/${1}/comments?per_page=100" 2> /dev/null
}

# Get the list of files changed in a PR
# Usage: ci_get_pr_changed_files <pr_number> [<org/repo>]
ci_get_pr_changed_files() {
    local pr_number="$1"
    local repo_arg="${2:-}"
    local repo_flag=()
    ci_repo_flag repo_flag "${repo_arg}"
    gh pr diff "${pr_number}" "${repo_flag[@]}" --name-only 2> /dev/null || echo ""
}

# JSON output helper
ci_json_error() {
    local message="$1"
    jq -n --arg msg "${message}" '{"error": $msg}'
}
