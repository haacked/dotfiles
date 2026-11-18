#!/usr/bin/env bash
# fetch-unaddressed-comments.sh - Fetch review feedback, minus dismissed items
#
# Usage: fetch-unaddressed-comments.sh <repo> <pr_number>
#
# Output: JSON array of review feedback that has NOT been previously dismissed
# or recorded as handled. Each item has:
#   {id, kind, path, line, body, diff_hunk, author, is_bot, url}
#
# kind is one of:
#   inline       the root comment of an unresolved review thread, from any reviewer
#   review_body  the body of a submitted review, in any state
#   pr_comment   a top-level comment in the PR conversation
#
# path, line, and diff_hunk are null for review_body and pr_comment. url is null
# for inline. The ids of different kinds come from different GitHub tables. An
# item's kind and id together identify it.
#
# A review body or top-level comment is dropped when its body is blank, when the
# PR author wrote it, when a bot wrote it, or when it is an `@posthog review`
# request. Bots post status, summaries, and CI reports there, and they deliver
# their findings as inline threads.
#
# Reads dismissed-comment hashes from the shared state file at:
#   ~/.local/state/copilot-review-loop/{owner}-{repo_name}-{pr_number}.json

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/copilot.sh
source "${SCRIPT_DIR}/lib/copilot.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number>" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"

STATE_FILE=$(dismissed_state_file "$REPO" "$PR_NUMBER")

# The trigger pattern matches is_reviewhog_trigger in helpers/pending-reviews.jq,
# which go's merge gate also uses. A test fails when the two patterns differ.
# shellcheck disable=SC2016  # $author, $inline, $reviews, and $comments are jq variables
ITEMS_JQ='
  .[0] as $inline
  | .[1] as $reviews
  | .[2] as $comments
  | def keep:
    ((.body // "") | test("\\S"))
    and ((.user.login // "") != $author)
    and ((.user.type // "") != "Bot")
    and ((.body // "") | ascii_downcase | test("^\\s*@posthog\\s+review(\\s|$)") | not);
  def item($kind): {
    id,
    kind: $kind,
    path: null,
    line: null,
    body,
    diff_hunk: null,
    author: (.user.login // "unknown"),
    is_bot: false,
    url: .html_url
  };
  [ ($inline[] | . + {kind: "inline", url: null}),
    ($reviews[][] | select(keep) | item("review_body")),
    ($comments[][] | select(keep) | item("pr_comment")) ]
'

inline=$(fetch_unresolved_review_comments)
pr_author=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}" | jq -r '.user.login // ""')
reviews=$(gh api --paginate --slurp "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100")
issue_comments=$(gh api --paginate --slurp "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100")

items=$(jq -sc --arg author "$pr_author" "$ITEMS_JQ" \
  <(echo "$inline") <(echo "$reviews") <(echo "$issue_comments"))

if [[ "$items" == "[]" ]]; then
  echo "[]"
  exit 0
fi

# Load dismissed hashes from the state file, normalizing both entry shapes:
# objects from the review loop and bare hash strings from older skill runs.
# read_state_file fails loud on a corrupt file, ending the run via errexit.
state=$(read_state_file "$STATE_FILE")
dismissed_hashes=$(echo "$state" | jq -r "$DISMISSED_OBJECTS_JQ"' | .body_hash')

declare -A dismissed_set
while IFS= read -r h; do
  [[ -n "$h" ]] && dismissed_set["$h"]=1
done <<< "$dismissed_hashes"

tmpfile=$(mktemp)
trap 'rm -f "$tmpfile"' EXIT

while IFS= read -r item; do
  body=$(echo "$item" | jq -r '.body')
  body_hash=$(hash_comment "$body")
  if [[ -z "${dismissed_set[$body_hash]+isset}" ]]; then
    echo "$item" >> "$tmpfile"
  fi
done < <(echo "$items" | jq -c '.[]')

if [[ -s "$tmpfile" ]]; then
  jq -s '.' < "$tmpfile"
else
  echo "[]"
fi
