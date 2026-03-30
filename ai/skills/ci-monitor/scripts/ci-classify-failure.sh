#!/usr/bin/env bash
# ci-classify-failure.sh - Classify a CI failure as flaky or legit
#
# Usage:
#   ci-classify-failure.sh <pr_number> <workflow_name> [<org/repo>]
#
# Reads log_excerpt from stdin.
#
# Output: JSON with classification (flaky/legit/uncertain), confidence, reasoning, signals

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq git awk grep

pr_number="${1:?Usage: ci-classify-failure.sh <pr_number> <workflow_name> [<org/repo>]}"
workflow_name="${2:?Usage: ci-classify-failure.sh <pr_number> <workflow_name> [<org/repo>]}"
repo_arg="${3:-}"

repo_flag=()
ci_repo_flag repo_flag "${repo_arg}"

# Read log excerpt from stdin
log_excerpt=$(cat)

# ── Signal 1: Does the same workflow fail on the default branch? ─────────────

fails_on_default_branch="false"
main_reasoning=""

# Get default branch
default_branch=$(gh repo view "${repo_flag[@]}" --json defaultBranchRef -q '.defaultBranchRef.name' 2> /dev/null || echo "main")

# Check recent runs on the default branch
main_runs=$(gh run list \
    --branch "${default_branch}" \
    "${repo_flag[@]}" \
    --workflow "${workflow_name}" \
    --limit 5 \
    --json conclusion \
    2> /dev/null) || main_runs="[]"

read -r main_failure_count main_total < <(echo "${main_runs}" | jq -r '[([.[] | select(.conclusion == "failure")] | length), length] | @tsv')

if [[ "${main_failure_count}" -gt 0 ]]; then
    fails_on_default_branch="true"
    main_reasoning="Workflow '${workflow_name}' has ${main_failure_count}/${main_total} recent failures on ${default_branch}"
fi

# ── Signal 2: Do error logs reference PR-changed files? ──────────────────────

references_changed_files="false"
changed_file_matches=""

# Get PR changed files
changed_files=$(ci_get_pr_changed_files "${pr_number}" "${repo_arg}")

if [[ -n "${changed_files}" ]] && [[ -n "${log_excerpt}" ]]; then
    declare -A seen_files=()
    # Build a pattern file with full paths and basenames for a single grep pass
    patterns=""
    declare -A file_for_pattern=()
    while IFS= read -r file; do
        [[ -z "${file}" ]] && continue
        patterns+="${file}"$'\n'
        file_for_pattern["${file}"]="${file}"
        basename_file="${file##*/}"
        patterns+="${basename_file}"$'\n'
        file_for_pattern["${basename_file}"]="${file}"
    done <<< "${changed_files}"

    if [[ -n "${patterns}" ]]; then
        matched_patterns=$(grep -oF -- "${patterns%$'\n'}" <<< "${log_excerpt}" 2>/dev/null | sort -u) || true
        while IFS= read -r pat; do
            [[ -z "${pat}" ]] && continue
            file="${file_for_pattern["${pat}"]:-}"
            [[ -n "${file}" ]] && seen_files["${file}"]=1
        done <<< "${matched_patterns}"
    fi

    if [[ ${#seen_files[@]} -gt 0 ]]; then
        references_changed_files="true"
        changed_file_matches=$(printf '%s, ' "${!seen_files[@]}")
        changed_file_matches="${changed_file_matches%, }"
    fi
fi

# ── Signal 3: Known flaky patterns in logs ───────────────────────────────────

known_flaky_pattern="false"
flaky_pattern_match=""

# Common flaky test indicators
flaky_patterns=(
    "timed out"
    "deadline exceeded"
    "ETIMEDOUT"
    "ECONNRESET"
    "ECONNREFUSED"
    "connection refused"
    "socket hang up"
    "lock timeout"
    "could not obtain lock"
    "runner lost communication"
    "The runner has received a shutdown signal"
    "net/http: request canceled"
    "context deadline exceeded"
    "ResourceExhausted"
    "Too many open files"
    "no space left on device"
)

if [[ -n "${log_excerpt}" ]]; then
    flaky_pattern_match=$(grep -oiFf <(printf '%s\n' "${flaky_patterns[@]}") <<< "${log_excerpt}" | head -1) || true
    if [[ -n "${flaky_pattern_match}" ]]; then
        known_flaky_pattern="true"
    fi
fi

# ── Combine signals ──────────────────────────────────────────────────────────

# Scoring: start at 0.5 (uncertain)
# Flaky signals decrease score, legit signals increase
score=50 # Using integers to avoid bash float issues

if [[ "${fails_on_default_branch}" == "true" ]]; then
    score=$((score - 30))
fi

if [[ "${references_changed_files}" == "true" ]]; then
    score=$((score + 30))
fi

if [[ "${known_flaky_pattern}" == "true" ]]; then
    score=$((score - 15))
fi

# Classification thresholds
if [[ ${score} -le 35 ]]; then
    classification="flaky"
elif [[ ${score} -ge 65 ]]; then
    classification="legit"
else
    classification="uncertain"
fi

# Build reasoning
reasoning=""
if [[ "${fails_on_default_branch}" == "true" ]]; then
    reasoning="${main_reasoning}. "
fi
if [[ "${references_changed_files}" == "true" ]]; then
    reasoning="${reasoning}Error logs reference PR-changed files: ${changed_file_matches}. "
fi
if [[ "${known_flaky_pattern}" == "true" ]]; then
    reasoning="${reasoning}Log contains known flaky pattern: '${flaky_pattern_match}'. "
fi
if [[ -z "${reasoning}" ]]; then
    reasoning="No strong signals detected."
fi
# Trim trailing space
reasoning="${reasoning% }"

# Confidence: distance from 50 (uncertain center)
if [[ ${score} -ge 50 ]]; then
    confidence_raw=$((score - 50))
else
    confidence_raw=$((50 - score))
fi
# Scale to 0.5-1.0 range (0.5 at score 50, 1.0 at max distance 50)
confidence=$(awk -v raw="${confidence_raw}" 'BEGIN { printf "%.2f", 0.5 + (raw / 100.0) }')

# ── Output ───────────────────────────────────────────────────────────────────

jq -n \
    --arg classification "${classification}" \
    --arg confidence "${confidence}" \
    --arg reasoning "${reasoning}" \
    --argjson fails_on_default_branch "${fails_on_default_branch}" \
    --argjson references_changed_files "${references_changed_files}" \
    --argjson known_flaky_pattern "${known_flaky_pattern}" \
    --arg flaky_pattern_match "${flaky_pattern_match}" \
    --arg changed_file_matches "${changed_file_matches}" \
    '{
    classification: $classification,
    confidence: ($confidence | tonumber),
    reasoning: $reasoning,
    signals: {
      fails_on_default_branch: $fails_on_default_branch,
      references_changed_files: $references_changed_files,
      known_flaky_pattern: $known_flaky_pattern,
      flaky_pattern_match: $flaky_pattern_match,
      changed_file_matches: $changed_file_matches
    }
  }'
