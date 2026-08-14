#!/usr/bin/env bash
# ci-requeue-check.sh - Decide whether a dropped PR can be auto-re-enqueued.
#
# A PR the Trunk merge queue dropped can be put back with a `/trunk merge`
# comment, but posting one is safe only when the drop is confirmed and current:
# the same comment on a PR that is waiting to get in forfeits its submission,
# and one on a PR a human cancelled overrides their call. This verifies every
# mechanical condition; the judgment call - was the failure flaky or unrelated
# to this PR? - stays with the caller.
#
# This script is READ-ONLY: it emits a verdict and never comments, enqueues, or
# pushes. The decision is a pure function (helpers/requeue-verdict.jq); this
# wrapper only gathers inputs, re-running ci-queue-status.sh itself so the
# verdict describes the moment of decision - a merge branch that reappeared
# since the caller's last poll flips the state to `testing` and denies. It
# fails closed (requeue_ok:false) on any error or uncertainty.
#
# --after-fix waives the comment-freshness condition. Pass it only when this
# session verified the drop, pushed a fix, and watched the PR's own CI go
# green - the eviction comment then legitimately predates the head.
#
# Usage:
#   ci-requeue-check.sh <pr_number> [<org/repo>] [--after-fix]
#
# Output: JSON { requeue_ok, reasons, state, blocked_reason, dropped_marker,
#                comment_after_head, merge_pr, merge_pr_verified,
#                pr_mergeable, enqueue_comments_since_head,
#                max_auto_requeues, head_sha, head_committed_at }

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq

VERDICT_JQ="${SCRIPT_DIR}/helpers/requeue-verdict.jq"

# Emit a fail-closed verdict and exit 0 (callers parse JSON, not exit codes).
emit_denied() {
    jq -n --arg reason "$1" '{
        requeue_ok: false, reasons: [$reason],
        state: null, blocked_reason: null, dropped_marker: null,
        comment_after_head: null, merge_pr: null, merge_pr_verified: false,
        pr_mergeable: null,
        enqueue_comments_since_head: null, max_auto_requeues: null,
        head_sha: null, head_committed_at: null
    }'
    exit 0
}

pr_number="${1:?Usage: ci-requeue-check.sh <pr_number> [<org/repo>] [--after-fix]}"
shift
repo_arg=""
after_fix="false"
for arg in "$@"; do
    case "${arg}" in
        --after-fix) after_fix="true" ;;
        --*) emit_denied "unknown flag: ${arg}" ;;
        *) repo_arg="${arg}" ;;
    esac
done

repo_flag=()
ci_repo_flag repo_flag "${repo_arg}"

# ── Queue state, at the moment of decision ───────────────────────────────────

queue=$("${SCRIPT_DIR}/ci-queue-status.sh" "${pr_number}" ${repo_arg:+"${repo_arg}"} 2> /dev/null) \
    || emit_denied "could not read queue status"
queue_error=$(echo "${queue}" | jq -r '.error // empty' 2> /dev/null) || queue_error="unparseable output"
queue_state=$(echo "${queue}" | jq -r '.state // empty' 2> /dev/null) || queue_state=""
[[ -z "${queue_error}" && -n "${queue_state}" ]] \
    || emit_denied "queue status unreadable: ${queue_error:-no state field}"

# ── PR and merge-PR identity ─────────────────────────────────────────────────

# Deliberately re-read rather than taken from the queue JSON: the verdict acts
# on this state, so it is fetched at the moment of decision, like the queue
# re-run above. mergeable and isDraft feed the verdict's futility conditions.
pr_info=$(gh pr view "${pr_number}" "${repo_flag[@]}" \
    --json state,mergeable,isDraft \
    --jq '{state, mergeable, is_draft: .isDraft}' 2> /dev/null) \
    || emit_denied "could not fetch PR #${pr_number}"

# gh pr view renders app authors as app/<slug>; the trunk-io[bot] the comments
# API reports is the same identity. The verdict checks head prefix and author.
merge_pr=$(echo "${queue}" | jq -r '.merge_pr // empty')
merge_pr_info='{"head": null, "author": null, "state": null}'
if [[ -n "${merge_pr}" ]]; then
    merge_pr_info=$(gh pr view "${merge_pr}" "${repo_flag[@]}" \
        --json headRefName,author,state \
        --jq '{head: .headRefName, author: .author.login, state: .state}' 2> /dev/null) \
        || emit_denied "could not fetch merge PR #${merge_pr}"
fi

# ── Verdict ──────────────────────────────────────────────────────────────────
# The auto-requeue budget (exact-body `/trunk merge` comments since the head
# commit, so it resets on a new head by construction) arrives inside the queue
# JSON as enqueue_comments_since_head - counted by queue-state.jq from the one
# comments fetch ci-queue-status.sh already makes.

jq -n \
    --arg pr_number "${pr_number}" \
    --argjson pr_info "${pr_info}" \
    --argjson queue "${queue}" \
    --argjson merge_pr_info "${merge_pr_info}" \
    --argjson max "${CI_MAX_AUTO_REQUEUES}" \
    --argjson after_fix "${after_fix}" \
    '{queue: $queue, pr_number: $pr_number, pr_state: $pr_info.state,
      pr_mergeable: $pr_info.mergeable, pr_is_draft: $pr_info.is_draft,
      merge_pr_head: $merge_pr_info.head,
      merge_pr_author: $merge_pr_info.author,
      merge_pr_state: $merge_pr_info.state,
      max_auto_requeues: $max, after_fix: $after_fix}' \
    | jq -f "${VERDICT_JQ}"
