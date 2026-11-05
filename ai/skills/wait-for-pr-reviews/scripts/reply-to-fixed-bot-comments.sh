#!/usr/bin/env bash
# Reply to each fixed bot review comment with the short hash of HEAD, then resolve
# the threads those replies answer.
#
# Usage: reply-to-fixed-bot-comments.sh <owner/repo> <pr_number> <fixed-file>
#
# Each line of <fixed-file> holds a review comment id, a tab, and one sentence that
# says what the code does now. The reply reads "Fixed in <hash>: <sentence>". Run
# this only after the push of HEAD to the PR succeeded, because the reply cites it.
#
# A comment gets a reply only when it opens an unresolved thread and
# fetch_unresolved_review_comments marks its author as a bot. Any other comment gets
# no reply, so a human reviewer's thread stays open. A thread whose reply fails to
# post also stays open.

set -euo pipefail

if [[ $# -ne 3 ]]; then
  echo "Usage: $(basename "$0") <owner/repo> <pr_number> <fixed-file>" >&2
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/logging.sh"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/lib/copilot.sh"

REPO="$1"
PR_NUMBER="$2"
fixed_file="$3"

hash=$(git rev-parse --short HEAD)
if ! bot_ids=$(fetch_unresolved_review_comments | jq -c '[.[] | select(.is_bot) | .id]'); then
  echo "Could not read the PR's review threads, so no reply was posted." >&2
  exit 1
fi

resolve_args=()
failed=0

while IFS=$'\t' read -r id sentence; do
  if [[ ! "$id" =~ ^[0-9]+$ || -z "$sentence" ]]; then
    echo "Skipping a line that is not '<comment id><tab><sentence>': ${id}" >&2
    failed=1
    continue
  fi
  if ! jq -e --argjson id "$id" 'index($id) != null' <<<"$bot_ids" >/dev/null; then
    echo "Comment ${id} does not open an unresolved bot thread, so it gets no reply."
    continue
  fi

  reply="Fixed in ${hash}: ${sentence}"
  if gh api "repos/${REPO}/pulls/${PR_NUMBER}/comments/${id}/replies" --method POST \
    -f body="$reply" >/dev/null; then
    echo "Replied to comment ${id}: ${reply}"
    resolve_args+=(--comment-id "$id")
  else
    echo "Posting the reply to comment ${id} failed, so its thread stays open." >&2
    failed=1
  fi
done < <(awk -F'\t' '!seen[$1]++' "$fixed_file")

if [[ ${#resolve_args[@]} -gt 0 ]]; then
  # gh-resolve-threads exits 0 when a resolve mutation fails, so the script reads
  # failedCount from its JSON. The log lines come before the JSON on stdout.
  resolve_status=0
  resolve_out=$("${SCRIPT_DIR}/gh-resolve-threads" "https://github.com/${REPO}/pull/${PR_NUMBER}" "${resolve_args[@]}" --json) || resolve_status=$?
  sed '/^{/,$d' <<<"$resolve_out"
  if [[ $resolve_status -ne 0 ]] || ! sed -n '/^{/,$p' <<<"$resolve_out" | jq -e '(.failedCount // 0) == 0' >/dev/null; then
    echo "Resolving at least one replied thread failed, so that thread stays open." >&2
    failed=1
  fi
fi

exit "$failed"
