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
# gathers inputs. It reports "no_queue" on a repo with no Trunk merge queue, so
# callers can run it unconditionally, at a cost of about four gh calls (one of
# which pages the PR's comments) and roughly two seconds. Three always fire; the
# rest depend on what those find - the head commit's date when the PR has a status
# comment, the repo-wide queue probe when it has neither a comment nor a merge
# branch, and one call per merge branch to resolve it to a PR. Omitting <org/repo>
# adds one to look it up.
#
# Requires gh 2.53+ for `api --slurp`.
#
# Usage:
#   ci-queue-status.sh <pr_number> [<org/repo>]
#
# Output: JSON { state, queue_active, merge_branch, merge_pr, merge_pr_source,
#                comment_after_head, head_sha, head_committed_at,
#                last_queue_comment }
#
# state is one of landed | testing | blocked | not_enqueued | no_queue.
# merge_pr, when set, is a normal PR whose checks carry the queue's CI results -
# pass it to ci-check-status.sh to monitor or triage the queue run.
#
# `blocked` deliberately spans "dropped out of the queue" and "submitted, waiting
# to get in" - Trunk distinguishes them only in the prose of its status comment,
# which this never reads for a verdict. Callers deciding whether a push is safe
# must treat `blocked` as unsafe; see queue-state.jq.

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

# Every gh fallback below puts `||` outside the command substitution. `gh api`
# writes HTTP error bodies to stdout, so `$(gh api … || echo "[]")` captures the
# error body *concatenated* with the default, which is not one JSON document and
# kills the final --argjson. That would emit neither a state nor an error, and a
# caller gating a push on "not testing" would read the silence as safe.

# ── Trunk merge branches ─────────────────────────────────────────────────────
# matching-refs is a prefix match. The trailing slash keeps pr-770 from matching
# pr-7701, and an absent prefix comes back as an empty array rather than a 404.

refs_for_pr=$(gh api "repos/${repo_nwo}/git/matching-refs/heads/trunk-merge/pr-${pr_number}/" \
    --jq '[.[].ref]' 2> /dev/null) || refs_for_pr="[]"

# ── Trunk's status comment ───────────────────────────────────────────────────
# Trunk keeps one status comment per PR and edits it in place as the PR moves
# through the queue, so the most recently updated one is the current status. Its
# test-analytics post is excluded: that appears on every PR and says nothing
# about the queue. --slurp cannot be combined with --jq, so filtering happens
# downstream. The verdict reads this comment's marker, timestamp, and merge PR
# link only - never its prose.
#
# Paginated in full rather than reading one page: Trunk's comment is normally the
# PR's *oldest* (it posts on open and edits in place), so fetching the newest page
# would systematically miss it.

last_queue_comment=$(gh api --paginate --slurp \
    "repos/${repo_nwo}/issues/${pr_number}/comments?per_page=100" 2> /dev/null \
    | jq --arg bot "${TRUNK_BOT}" '
        [ .[][]
          | select(.user.login == $bot and .user.type == "Bot")
          | select((.body // "") | contains("<!-- Trunk Test Analytics -->") | not)
          | {created_at, updated_at, html_url, body} ]
        | sort_by(.updated_at) | last // null' 2> /dev/null) || last_queue_comment="null"
[[ -n "${last_queue_comment}" ]] || last_queue_comment="null"

# A branch for this PR, or a status comment, already proves the queue is in use.
# The repo-wide probe is the last resort because it detects only whether some PR
# is being tested *right now* - Trunk deletes each branch when its attempt ends,
# so a quiet queue looks identical to no queue.
if [[ "$(echo "${refs_for_pr}" | jq 'length')" -gt 0 ]] || [[ "${last_queue_comment}" != "null" ]]; then
    queue_active="true"
else
    queue_active=$(gh api "repos/${repo_nwo}/git/matching-refs/heads/trunk-merge/" \
        --jq '(length > 0) | tostring' 2> /dev/null) || queue_active="false"
fi

# Only feeds comment_after_head, which is null without a comment, so it is not
# worth a request on a repo Trunk has never touched.
head_committed_at=""
if [[ -n "${head_sha}" ]] && [[ "${last_queue_comment}" != "null" ]]; then
    # The GitHub API normalizes commit dates to UTC, which is what makes the
    # freshness comparison in the verdict a string compare.
    head_committed_at=$(gh api "repos/${repo_nwo}/commits/${head_sha}" \
        --jq '.commit.committer.date // ""' 2> /dev/null) || head_committed_at=""
fi

# Trunk's merge branch is itself a normal PR, so its checks are readable with the
# same tooling as any other PR. matching-refs sorts by name and Trunk's suffix is
# a UUID, so array position says nothing about which attempt is live; merge PR
# numbers are monotonic, so the highest is the newest attempt. A ref whose PR
# cannot be resolved still counts as testing - the branch exists either way.
merge_pr_from_ref="null"
merge_branch=""
while IFS= read -r ref; do
    [[ -n "${ref}" ]] || continue
    candidate="${ref#refs/heads/}"
    number=$(gh pr list "${repo_flag[@]}" --head "${candidate}" --state all \
        --json number --jq '.[0].number // empty' 2> /dev/null) || number=""
    if [[ -n "${number}" ]] \
        && { [[ "${merge_pr_from_ref}" == "null" ]] || [[ "${number}" -gt "${merge_pr_from_ref}" ]]; }; then
        merge_pr_from_ref="${number}"
        merge_branch="${candidate}"
    fi
done < <(echo "${refs_for_pr}" | jq -r '.[]')

# No ref resolved to a PR (Trunk pushed the branch but has not opened its PR
# yet), so report a branch anyway rather than claiming there is none.
if [[ -z "${merge_branch}" ]]; then
    merge_branch=$(echo "${refs_for_pr}" | jq -r 'last // "" | sub("^refs/heads/"; "")')
fi

# ── Verdict ──────────────────────────────────────────────────────────────────

jq -n \
    --arg owner "${owner}" \
    --arg repo "${repo}" \
    --arg head_sha "${head_sha}" \
    --arg head_committed_at "${head_committed_at}" \
    --arg merge_branch "${merge_branch}" \
    --argjson pr_merged "${pr_merged}" \
    --argjson refs_for_pr "${refs_for_pr}" \
    --argjson queue_active "${queue_active}" \
    --argjson merge_pr_from_ref "${merge_pr_from_ref}" \
    --argjson last_queue_comment "${last_queue_comment}" \
    '{owner: $owner, repo: $repo, pr_merged: $pr_merged, head_sha: $head_sha,
      head_committed_at: $head_committed_at, refs_for_pr: $refs_for_pr,
      merge_branch: $merge_branch,
      queue_active: $queue_active, merge_pr_from_ref: $merge_pr_from_ref,
      last_queue_comment: $last_queue_comment}' \
    | jq -f "${STATE_JQ}"
