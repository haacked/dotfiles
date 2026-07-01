#!/usr/bin/env bash
# ci-approval-safety.sh - Decide whether a re-gated fork PR can be auto-approved.
#
# An outside-contributor (fork) PR re-gates its workflows on every new push,
# including a maintainer/contributor clicking "Update branch" (a merge or rebase
# of the base branch). This script reports whether the only change since the
# last approval was such a base-branch sync, with no new contributor code - in
# which case re-approval is as safe as the approval you already gave.
#
# This script is READ-ONLY: it emits a verdict and never approves anything.
# The decision is a pure function (helpers/approval-safety.jq); this wrapper only
# gathers the inputs. It fails closed (safe:false) on any error or uncertainty.
#
# Usage:
#   ci-approval-safety.sh <pr_number> [<org/repo>]
#
# Output: JSON { safe, reason, last_approved_sha, current_head_sha,
#                gated_count, gated_workflows, gated_run_ids }
#
# gated_run_ids holds every gated run at the verified current head. The caller
# approves exactly these ids, so "what was verified" and "what gets approved" are
# the same set of runs at the same sha, not two snapshots taken at different times.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq

DECISION_JQ="${SCRIPT_DIR}/helpers/approval-safety.jq"
LAST_APPROVED_JQ="${SCRIPT_DIR}/helpers/last-approved-sha.jq"

pr_number="${1:?Usage: ci-approval-safety.sh <pr_number> [<org/repo>]}"
repo_arg="${2:-}"

repo_flag=()
ci_repo_flag repo_flag "${repo_arg}"

# Emit a fail-closed verdict and exit 0 (callers parse JSON, not exit codes).
emit_unsafe() {
    jq -n --arg reason "$1" '{
        safe: false, reason: $reason,
        last_approved_sha: null, current_head_sha: null,
        gated_count: 0, gated_workflows: [], gated_run_ids: []
    }'
    exit 0
}

# ── PR identity ──────────────────────────────────────────────────────────────

pr_json=$(gh pr view "${pr_number}" "${repo_flag[@]}" \
    --json headRefName,headRefOid,baseRefName,isCrossRepository,headRepositoryOwner \
    2> /dev/null) || emit_unsafe "could not fetch PR #${pr_number}"

IFS=$'\t' read -r head_branch current_head_sha base_ref is_cross_repo fork_owner < <(
    echo "${pr_json}" | jq -r '[
        .headRefName // "",
        .headRefOid // "",
        .baseRefName // "",
        (.isCrossRepository // false | tostring),
        .headRepositoryOwner.login // ""
    ] | @tsv')

[[ "${is_cross_repo}" == "true" ]] || emit_unsafe "not a fork PR; approval gating does not apply"
[[ -n "${current_head_sha}" && -n "${base_ref}" ]] || emit_unsafe "could not resolve PR head/base"

repo_nwo="${repo_arg}"
if [[ -z "${repo_nwo}" ]]; then
    repo_nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || echo "")
fi
[[ -n "${repo_nwo}" ]] || emit_unsafe "could not resolve owner/repo"

# ── Gated runs at the current head ───────────────────────────────────────────
# Every run currently held for approval at the verified head, ungrouped: the
# caller approves these exact run_ids, so the set verified here is the set
# approved. Restricted to pull_request(_target) so unrelated action_required runs
# never appear. The verdict refuses any pull_request_target gated run outright,
# and sees every run (not one-per-workflow) so a target run can't hide behind a
# same-named pull_request run.

gated_runs=$(gh api \
    "repos/${repo_nwo}/actions/runs?head_sha=${current_head_sha}&status=action_required&per_page=100" \
    --jq '[.workflow_runs[]
           | select(.conclusion == "action_required")
           | select(.event == "pull_request" or .event == "pull_request_target")
           | {event: .event, run_id: .id, workflow: .name}]' \
    2> /dev/null) || emit_unsafe "could not query gated runs"
gated_count=$(echo "${gated_runs}" | jq 'length')

# Nothing gated means nothing to approve; skip the heavier prior-runs and compare
# fetches below, which would only reach the same fail-closed verdict.
[[ "${gated_count}" -gt 0 ]] || emit_unsafe "no gated runs awaiting approval"

# ── Last approved head sha ───────────────────────────────────────────────────
# The head sha of the most recent run for this fork branch that already ran.
# Matched on head_branch + fork owner to disambiguate same-named branches from
# other forks. The selection is a pure function (helpers/last-approved-sha.jq)
# so it can be fixture-tested; `gh api --jq` cannot define the $fork variable, so
# fetch raw and pipe to jq.
runs_raw=$(gh api \
    "repos/${repo_nwo}/actions/runs?event=pull_request&branch=${head_branch}&per_page=100" \
    2> /dev/null) || emit_unsafe "could not query prior runs"
last_approved_sha=$(echo "${runs_raw}" | jq -r --arg fork "${fork_owner}" -f "${LAST_APPROVED_JQ}")

# ── Three-dot compares (only when needed) ────────────────────────────────────
# Resolve the base branch to a single sha and reuse it for both compares, so a
# merge to master landing between the two API calls can't cause a spurious
# mismatch.

compare_then='{}'
compare_now='{}'
if [[ -n "${last_approved_sha}" && "${last_approved_sha}" != "${current_head_sha}" ]]; then
    base_sha=$(gh api "repos/${repo_nwo}/commits/${base_ref}" -q .sha 2> /dev/null || echo "")
    [[ -n "${base_sha}" ]] || emit_unsafe "could not resolve base branch '${base_ref}' to a sha"

    # Keep only the head blob sha per changed file: the content signature the
    # verdict compares. Identical for both compares so it lives in one place.
    compare_fields='{files: [(.files // [])[] | {filename, status, sha, previous_filename}]}'
    compare_then=$(gh api "repos/${repo_nwo}/compare/${base_sha}...${last_approved_sha}" \
        --jq "${compare_fields}" 2> /dev/null) || emit_unsafe "could not compare base...last_approved_sha"
    compare_now=$(gh api "repos/${repo_nwo}/compare/${base_sha}...${current_head_sha}" \
        --jq "${compare_fields}" 2> /dev/null) || emit_unsafe "could not compare base...current_head"
fi

# ── Verdict ──────────────────────────────────────────────────────────────────

verdict=$(jq -n \
    --arg last "${last_approved_sha}" \
    --arg cur "${current_head_sha}" \
    --argjson runs "${gated_runs}" \
    --argjson c_then "${compare_then}" \
    --argjson c_now "${compare_now}" \
    '{last_approved_sha: $last, current_head_sha: $cur,
      gated_runs: $runs, compare_then: $c_then, compare_now: $c_now}' \
    | jq -f "${DECISION_JQ}")

# Attach gated-run context for the caller's alert. gated_run_ids is every gated
# run to approve; gated_workflows/gated_count are deduped by workflow for display.
echo "${verdict}" | jq \
    --argjson runs "${gated_runs}" \
    '. + {gated_count: ([$runs[].workflow] | unique | length),
          gated_workflows: ([$runs[].workflow] | unique),
          gated_run_ids: [$runs[].run_id]}'
