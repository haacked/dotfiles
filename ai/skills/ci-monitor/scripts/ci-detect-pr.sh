#!/usr/bin/env bash
# ci-detect-pr.sh - Detect PR from current branch or argument
#
# Usage:
#   ci-detect-pr.sh [<pr-number>|<pr-url>]
#
# When no argument is given, detects the PR from the current branch.
#
# Output: JSON object with pr_number, org, repo, head_branch, head_sha, error

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq git

arg="${1:-}"

# ── Parse argument ───────────────────────────────────────────────────────────

if [[ -n "${arg}" ]]; then
    if [[ "${arg}" =~ ^https?://[^/]+/([^/]+)/([^/]+)/pull/([0-9]+) ]]; then
        # PR URL
        org="${BASH_REMATCH[1]}"
        repo="${BASH_REMATCH[2]}"
        pr_number="${BASH_REMATCH[3]}"

        # Normalize to lowercase
        org=$(echo "${org}" | tr '[:upper:]' '[:lower:]')
        repo=$(echo "${repo}" | tr '[:upper:]' '[:lower:]')

        # Fetch PR metadata
        pr_json=$(gh pr view "${pr_number}" \
            --repo "${org}/${repo}" \
            --json headRefName,headRefOid \
            2> /dev/null) || {
            ci_json_error "Could not fetch PR #${pr_number} from ${org}/${repo}"
            exit 0
        }

        head_branch=$(echo "${pr_json}" | jq -r '.headRefName')
        head_sha=$(echo "${pr_json}" | jq -r '.headRefOid')

    elif [[ "${arg}" =~ ^[0-9]+$ ]]; then
        # PR number - infer org/repo from current directory
        pr_number="${arg}"
        org_repo=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
        org="${org_repo%|*}"
        repo="${org_repo#*|}"

        if [[ "${org}" == "unknown" ]]; then
            ci_json_error "Could not determine repository. Run from within a git checkout."
            exit 0
        fi

        pr_json=$(gh pr view "${pr_number}" \
            --repo "${org}/${repo}" \
            --json headRefName,headRefOid \
            2> /dev/null) || {
            ci_json_error "Could not fetch PR #${pr_number}"
            exit 0
        }

        head_branch=$(echo "${pr_json}" | jq -r '.headRefName')
        head_sha=$(echo "${pr_json}" | jq -r '.headRefOid')
    else
        ci_json_error "Invalid argument: '${arg}'. Expected a PR number or PR URL."
        exit 0
    fi
else
    # No argument - detect from current branch
    validate_git_repo 2> /dev/null || {
        ci_json_error "Could not determine repository. Run from within a git checkout."
        exit 0
    }

    org_repo=$(get_git_org_repo 2> /dev/null || echo "unknown|unknown")
    org="${org_repo%|*}"
    repo="${org_repo#*|}"

    if [[ "${org}" == "unknown" ]]; then
        ci_json_error "Could not determine repository. Run from within a git checkout."
        exit 0
    fi

    head_branch=$(get_current_branch)

    if [[ -z "${head_branch}" ]]; then
        ci_json_error "Could not determine current branch (detached HEAD or not on a branch). Pass a PR number or PR URL explicitly."
        exit 0
    fi

    # Try to find an associated PR
    pr_json=$(gh pr view "${head_branch}" \
        --repo "${org}/${repo}" \
        --json number,headRefName,headRefOid \
        2> /dev/null) || {
        ci_json_error "No PR found for branch '${head_branch}'. Push your branch and create a PR first, or pass a PR number."
        exit 0
    }

    pr_number=$(echo "${pr_json}" | jq -r '.number')
    head_branch=$(echo "${pr_json}" | jq -r '.headRefName')
    head_sha=$(echo "${pr_json}" | jq -r '.headRefOid')
fi

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg pr_number "${pr_number}" \
    --arg org "${org}" \
    --arg repo "${repo}" \
    --arg head_branch "${head_branch}" \
    --arg head_sha "${head_sha}" \
    '{
    pr_number: ($pr_number | tonumber),
    org: $org,
    repo: $repo,
    head_branch: $head_branch,
    head_sha: $head_sha,
    error: null
  }'
