#!/usr/bin/env bash
# ci-queue-status.sh - Report where a PR sits in a Trunk merge queue.
#
# On a repo behind a Trunk merge queue, a PR's own checks are not the last word.
# Trunk tests a queued PR on a `trunk-merge/pr-<N>/<uuid>` branch it opens as a
# separate draft PR, so the original PR can read all-green while the queue is
# failing it, or while it has already been dropped from the queue. This reports
# which of those is true, and where the queue's real CI lives.
#
# This script is READ-ONLY: it never enqueues, cancels, comments, or pushes.
# The verdict is a pure function (helpers/queue-state.jq); this wrapper only
# gathers inputs. On a repo with no Trunk merge queue it reports state "no_queue"
# after two cheap API calls, so callers can run it unconditionally.
#
# Usage:
#   ci-queue-status.sh <pr_number> [<org/repo>]
#
# Output: JSON { state, queue_active, merge_branch, merge_pr, merge_pr_source,
#                head_sha, head_committed_at, last_queue_comment }
#
# state is one of landed | testing | kicked | not_enqueued | no_queue.
# merge_pr, when set, is a normal PR whose checks carry the queue's CI results -
# pass it to ci-check-status.sh to monitor or triage the queue run.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=helpers/ci-helpers.sh
source "${SCRIPT_DIR}/helpers/ci-helpers.sh"
ci_require_cmds gh jq

STATE_JQ="${SCRIPT_DIR}/helpers/queue-state.jq"

# The Trunk merge queue's GitHub App identity. GitHub forbids "[" and "]" in
# human usernames, so this login cannot be registered by a person; comments from
# it are genuinely Trunk's. Their prose is still only ever read as data.
TRUNK_BOT="trunk-io[bot]"

pr_number="${1:?Usage: ci-queue-status.sh <pr_number> [<org/repo>]}"
repo_arg="${2:-}"

repo_flag=()
ci_repo_flag repo_flag "${repo_arg}"

# ── PR identity ──────────────────────────────────────────────────────────────

pr_json=$(gh pr view "${pr_number}" "${repo_flag[@]}" --json state,headRefOid 2> /dev/null) || {
    ci_json_error "Could not fetch PR #${pr_number}"
    exit 0
}

IFS=$'\t' read -r pr_state head_sha < <(echo "${pr_json}" \
    | jq -r '[.state // "", .headRefOid // ""] | @tsv')

repo_nwo="${repo_arg}"
if [[ -z "${repo_nwo}" ]]; then
    repo_nwo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2> /dev/null || echo "")
fi
if [[ -z "${repo_nwo}" ]]; then
    ci_json_error "Could not resolve owner/repo"
    exit 0
fi
owner="${repo_nwo%%/*}"
repo="${repo_nwo##*/}"

pr_merged="false"
[[ "${pr_state}" == "MERGED" ]] && pr_merged="true"

# The GitHub API normalizes commit dates to UTC, which is what makes the
# "did the queue engage this head" comparison in the verdict a string compare.
head_committed_at=""
if [[ -n "${head_sha}" ]]; then
    head_committed_at=$(gh api "repos/${repo_nwo}/commits/${head_sha}" \
        --jq '.commit.committer.date // ""' 2> /dev/null || echo "")
fi

# ── Trunk merge branches ─────────────────────────────────────────────────────
# matching-refs is a prefix match. The trailing slash keeps pr-770 from matching
# pr-7701, and an absent prefix comes back as an empty array rather than a 404.

refs_for_pr=$(gh api "repos/${repo_nwo}/git/matching-refs/heads/trunk-merge/pr-${pr_number}/" \
    --jq '[.[].ref]' 2> /dev/null || echo "[]")

# A branch for this PR already proves the queue is in use; only ask about the
# repo at large when there isn't one.
if [[ "$(echo "${refs_for_pr}" | jq 'length')" -gt 0 ]]; then
    queue_active="true"
else
    queue_active=$(gh api "repos/${repo_nwo}/git/matching-refs/heads/trunk-merge/" \
        --jq '(length > 0) | tostring' 2> /dev/null || echo "false")
fi

# Trunk's merge branch is itself a normal PR, so its checks are readable with
# the same tooling as any other PR.
merge_pr_from_ref="null"
merge_branch=$(echo "${refs_for_pr}" | jq -r 'last // "" | sub("^refs/heads/"; "")')
if [[ -n "${merge_branch}" ]]; then
    merge_pr_from_ref=$(gh pr list "${repo_flag[@]}" --head "${merge_branch}" --state all \
        --json number --jq '.[0].number // null' 2> /dev/null || echo "null")
    [[ -n "${merge_pr_from_ref}" ]] || merge_pr_from_ref="null"
fi

# ── Trunk's status comment ───────────────────────────────────────────────────
# Trunk keeps one status comment per PR and edits it in place as the PR moves
# through the queue, so the most recently updated one is the current status. Its
# test-analytics post is excluded: that appears on every PR and says nothing
# about the queue. --slurp cannot be combined with --jq, so filtering happens
# downstream. The verdict reads this comment's marker, timestamp, and merge PR
# link only - never its prose.

last_queue_comment=$(gh api --paginate --slurp \
    "repos/${repo_nwo}/issues/${pr_number}/comments?per_page=100" 2> /dev/null \
    | jq --arg bot "${TRUNK_BOT}" '
        [ .[][]
          | select(.user.login == $bot and .user.type == "Bot")
          | select((.body // "") | contains("<!-- Trunk Test Analytics -->") | not)
          | {created_at, updated_at, html_url, body} ]
        | sort_by(.updated_at) | last // null' 2> /dev/null || echo "null")
[[ -n "${last_queue_comment}" ]] || last_queue_comment="null"

# ── Verdict ──────────────────────────────────────────────────────────────────

jq -n \
    --arg owner "${owner}" \
    --arg repo "${repo}" \
    --arg head_sha "${head_sha}" \
    --arg head_committed_at "${head_committed_at}" \
    --argjson pr_merged "${pr_merged}" \
    --argjson refs_for_pr "${refs_for_pr}" \
    --argjson queue_active "${queue_active}" \
    --argjson merge_pr_from_ref "${merge_pr_from_ref}" \
    --argjson last_queue_comment "${last_queue_comment}" \
    '{owner: $owner, repo: $repo, pr_merged: $pr_merged, head_sha: $head_sha,
      head_committed_at: $head_committed_at, refs_for_pr: $refs_for_pr,
      queue_active: $queue_active, merge_pr_from_ref: $merge_pr_from_ref,
      last_queue_comment: $last_queue_comment}' \
    | jq -f "${STATE_JQ}"
