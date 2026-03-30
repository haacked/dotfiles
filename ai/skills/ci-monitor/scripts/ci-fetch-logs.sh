#!/usr/bin/env bash
# ci-fetch-logs.sh - Fetch failure logs for a workflow run
#
# Usage:
#   ci-fetch-logs.sh <run_id> [<org/repo>]
#
# Output: JSON with structured failure log excerpts, truncated to last N lines per job

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq git awk

run_id="${1:?Usage: ci-fetch-logs.sh <run_id> [<org/repo>]}"
repo_arg="${2:-}"

repo_flag=()
ci_repo_flag repo_flag "${repo_arg}"

# ── Fetch run metadata ──────────────────────────────────────────────────────

run_json=$(gh run view "${run_id}" \
    "${repo_flag[@]}" \
    --json name,workflowName,conclusion,jobs \
    2> /dev/null) || {
    ci_json_error "Could not fetch run ${run_id}"
    exit 0
}

workflow_name=$(echo "${run_json}" | jq -r '.workflowName // .name // "unknown"')

# ── Fetch failed job logs ────────────────────────────────────────────────────

# gh run view --log-failed outputs logs prefixed with job/step names
gh_log_exit=0
raw_logs=$(gh run view "${run_id}" \
    "${repo_flag[@]}" \
    --log-failed \
    2> /dev/null) || gh_log_exit=$?

if [[ ${gh_log_exit} -ne 0 ]]; then
    ci_json_error "Could not fetch failure logs for run ${run_id} (gh exited ${gh_log_exit})"
    exit 0
fi

if [[ -z "${raw_logs}" ]]; then
    # gh succeeded but returned no output — run was cancelled or logs expired
    jq -n \
        --arg run_id "${run_id}" \
        --arg workflow "${workflow_name}" \
        '{
      run_id: ($run_id | tonumber),
      workflow: $workflow,
      failed_jobs: [],
      error: "No failure logs available. The run may have been cancelled or the logs expired."
    }'
    exit 0
fi

# Parse logs by job name (first tab-separated field)
# Group lines by job, keep last CI_LOG_TAIL_LINES per job
failed_jobs_json=$(printf '%s\n' "${raw_logs}" | awk -F'\t' -v tail_lines="${CI_LOG_TAIL_LINES}" '
function json_escape(s) {
  gsub(/\\/, "\\\\", s)
  gsub(/"/, "\\\"", s)
  gsub(/\t/, "\\t", s)
  gsub(/\r/, "", s)
  # Escape control characters (0x00-0x1F) that break JSON
  gsub(/\x00/, "", s)
  gsub(/\x01/, "", s)
  gsub(/\x02/, "", s)
  gsub(/\x03/, "", s)
  gsub(/\x04/, "", s)
  gsub(/\x05/, "", s)
  gsub(/\x06/, "", s)
  gsub(/\x07/, "", s)
  gsub(/\x08/, "\\b", s)
  gsub(/\x0b/, "", s)
  gsub(/\x0c/, "\\f", s)
  gsub(/\x0e/, "", s)
  gsub(/\x0f/, "", s)
  gsub(/\x10/, "", s)
  gsub(/\x11/, "", s)
  gsub(/\x12/, "", s)
  gsub(/\x13/, "", s)
  gsub(/\x14/, "", s)
  gsub(/\x15/, "", s)
  gsub(/\x16/, "", s)
  gsub(/\x17/, "", s)
  gsub(/\x18/, "", s)
  gsub(/\x19/, "", s)
  gsub(/\x1a/, "", s)
  gsub(/\x1b/, "", s)
  gsub(/\x1c/, "", s)
  gsub(/\x1d/, "", s)
  gsub(/\x1e/, "", s)
  gsub(/\x1f/, "", s)
  return s
}
BEGIN {
  job_count = 0
}
{
  job = $1
  log_line = ""
  for (i = 2; i <= NF; i++) {
    if (i > 2) log_line = log_line "\t"
    log_line = log_line $i
  }

  if (!(job in seen)) {
    seen[job] = 1
    jobs[job_count] = job
    job_count++
    line_count[job] = 0
  }

  idx = line_count[job] % tail_lines
  lines[job, idx] = log_line
  line_count[job]++
}
END {
  printf "["
  for (j = 0; j < job_count; j++) {
    job = jobs[j]
    count = line_count[job]
    start = 0
    total = count
    if (count > tail_lines) {
      start = count % tail_lines
      total = tail_lines
    }

    if (j > 0) printf ","
    printf "{\"name\":\"%s\",\"log_excerpt\":\"", json_escape(job)

    for (k = 0; k < total; k++) {
      idx = (start + k) % tail_lines
      line = lines[job, idx]
      if (k > 0) printf "\\n"
      printf "%s", json_escape(line)
    }
    printf "\"}"
  }
  printf "]"
}
')

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg run_id "${run_id}" \
    --arg workflow "${workflow_name}" \
    --argjson failed_jobs "${failed_jobs_json}" \
    '{
    run_id: ($run_id | tonumber),
    workflow: $workflow,
    failed_jobs: $failed_jobs,
    error: null
  }'
