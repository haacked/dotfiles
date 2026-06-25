#!/usr/bin/env bash
# ci-check-status.sh - Check CI status for a PR
#
# Usage:
#   ci-check-status.sh <pr_number> [<org/repo>]
#
# Output: JSON with overall status, pass/fail counts, per-check details, and
# any workflows awaiting maintainer approval (outside-contributor PRs).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq git

pr_number="${1:?Usage: ci-check-status.sh <pr_number> [<org/repo>]}"
repo_arg="${2:-}"

repo_flag=()
ci_repo_flag repo_flag "${repo_arg}"

# ── Fetch check status ──────────────────────────────────────────────────────

# gh pr checks returns structured JSON with check details
checks_json=$(gh pr checks "${pr_number}" \
    "${repo_flag[@]}" \
    --json name,state,bucket,link,workflow,event \
    2> /dev/null) || {
    ci_json_error "Could not fetch checks for PR #${pr_number}"
    exit 0
}

read -r total passed pending < <(echo "${checks_json}" | jq -r '[
    length,
    ([.[] | select(.bucket == "pass")] | length),
    ([.[] | select(.bucket == "pending")] | length)
  ] | @tsv')

# Real failures exclude action_required checks. gh buckets action_required as
# "fail", but those are workflows awaiting approval, not failures; they are
# detected and surfaced separately below. This predicate lives only here.
real_fail_checks=$(echo "${checks_json}" | jq '[.[] | select(.bucket == "fail" and .state != "ACTION_REQUIRED")]')
failed=$(echo "${real_fail_checks}" | jq 'length')

# ── PR head ref and fork status ─────────────────────────────────────────────
# Needed to enrich failed runs with IDs and to detect workflows awaiting
# maintainer approval on outside-contributor (fork) PRs.

pr_ref_json=$(gh pr view "${pr_number}" "${repo_flag[@]}" \
    --json headRefName,headRefOid,isCrossRepository 2> /dev/null || echo "{}")
IFS=$'\t' read -r head_branch head_sha is_cross_repo < <(echo "${pr_ref_json}" \
    | jq -r '[.headRefName // "", .headRefOid // "", (.isCrossRepository // false | tostring)] | @tsv')

# Resolve owner/repo for direct API calls (repo_arg is normally passed by the
# skill, but fall back to the current repo when it is not).
repo_nwo="${repo_arg}"
if [[ -z "${repo_nwo}" ]]; then
    repo_nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || echo "")
fi

# ── Detect workflows awaiting maintainer approval (fork PRs only) ────────────
# Outside-contributor PRs gate their pull_request workflows behind maintainer
# approval. These runs do NOT appear in `gh pr checks`; they surface only via
# the runs API as status=completed, conclusion=action_required. Restrict to
# pull_request(_target) events so review-triggered action_required runs (and the
# maintainer's own PRs) never trip a false positive. Only fork PRs can be gated,
# so skip the extra API call entirely on same-repo PRs.

awaiting_checks="[]"
if [[ "${is_cross_repo}" == "true" ]] && [[ -n "${head_sha}" ]] && [[ -n "${repo_nwo}" ]]; then
    awaiting_raw=$(gh api \
        "repos/${repo_nwo}/actions/runs?head_sha=${head_sha}&status=action_required&per_page=100" \
        --jq '[.workflow_runs[]
               | select(.conclusion == "action_required")
               | select(.event == "pull_request" or .event == "pull_request_target")
               | {link: .html_url, run_id: .id, workflow: .name}]' \
        2> /dev/null || echo "[]")
    # Dedupe by workflow, keeping the most recent run (API returns newest first).
    awaiting_checks=$(echo "${awaiting_raw}" | jq 'group_by(.workflow) | map(.[0])')
fi
awaiting_count=$(echo "${awaiting_checks}" | jq 'length')

if [[ "${total}" -eq 0 ]] && [[ "${awaiting_count}" -eq 0 ]]; then
    jq -n --argjson is_cross_repo "${is_cross_repo}" --arg head_sha "${head_sha}" '{
    status: "no_checks",
    all_passed: false,
    total: 0,
    passed: 0,
    failed: 0,
    pending: 0,
    awaiting_approval: 0,
    is_cross_repository: $is_cross_repo,
    head_sha: $head_sha,
    failed_checks: [],
    awaiting_approval_checks: []
  }'
    exit 0
fi

# Determine overall status
if [[ "${pending}" -gt 0 ]]; then
    status="in_progress"
else
    status="completed"
fi

# all_passed requires real passes with nothing failing, pending, or awaiting.
all_passed="false"
if [[ "${failed}" -eq 0 ]] && [[ "${pending}" -eq 0 ]] && [[ "${awaiting_count}" -eq 0 ]] && [[ "${passed}" -gt 0 ]]; then
    all_passed="true"
fi

# ── Get run IDs for failed checks ───────────────────────────────────────────
# We need run IDs to fetch failure logs. gh pr checks doesn't provide them,
# so we cross-reference with gh run list.

runs_json="[]"
if [[ "${failed}" -gt 0 ]] && [[ -n "${head_branch}" ]]; then
    runs_json=$(gh run list \
        --branch "${head_branch}" \
        "${repo_flag[@]}" \
        --limit 20 \
        --json databaseId,status,conclusion,name,workflowName,headSha \
        2> /dev/null) || runs_json="[]"
fi

# ── Build output ─────────────────────────────────────────────────────────────

# Enrich each failed check with its run ID by matching workflow name and head
# SHA. Matching on headSha picks the run for the current commit, not a stale
# rerun or manual trigger on an older SHA.
failed_checks=$(echo "${real_fail_checks}" | jq --argjson runs "${runs_json}" --arg head_sha "${head_sha}" '
  [.[] | . as $check |
    {
      name: .name,
      state: .state,
      bucket: .bucket,
      workflow: .workflow,
      link: .link,
      run_id: (
        $runs | map(select(
          (.conclusion == "failure") and
          (.workflowName == $check.workflow) and
          ($head_sha == "" or .headSha == $head_sha)
        )) | first | .databaseId // null
      )
    }
  ]
')

jq -n \
    --arg status "${status}" \
    --argjson all_passed "${all_passed}" \
    --argjson total "${total}" \
    --argjson passed "${passed}" \
    --argjson failed "${failed}" \
    --argjson pending "${pending}" \
    --argjson awaiting_approval "${awaiting_count}" \
    --argjson is_cross_repo "${is_cross_repo}" \
    --arg head_sha "${head_sha}" \
    --argjson failed_checks "${failed_checks}" \
    --argjson awaiting_approval_checks "${awaiting_checks}" \
    '{
    status: $status,
    all_passed: $all_passed,
    total: $total,
    passed: $passed,
    failed: $failed,
    pending: $pending,
    awaiting_approval: $awaiting_approval,
    is_cross_repository: $is_cross_repo,
    head_sha: $head_sha,
    failed_checks: $failed_checks,
    awaiting_approval_checks: $awaiting_approval_checks
  }'
