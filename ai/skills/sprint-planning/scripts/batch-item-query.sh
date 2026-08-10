#!/bin/bash
# Resolve fields for many GitHub issues/PRs in batched GraphQL queries,
# replacing N REST calls with one request per chunk of items. Shared by the
# sprint-planning and sprint-status helper scripts, which each build their own
# input array and join the response back by index.
#
# Usage:
#   echo '<json-array>' | batch-item-query.sh "<pr_fields>" "<issue_fields>"
#
# Stdin: JSON array of items, each: { owner, repo, type, number }
#   where type is "PullRequest" or "Issue". Extra fields are ignored.
# Args:
#   $1 pr_fields    - GraphQL selection set for pull requests,
#                     e.g. "state isDraft title"
#   $2 issue_fields - GraphQL selection set for issues,
#                     e.g. "state stateReason title"
#
# Output: a GraphQL response whose .data merges every chunk. Each input item is
#   aliased item_<index>, indexed by its position in the whole input rather than
#   in its chunk, so callers join by index. Prints nothing (empty string) when
#   the input is empty or every chunk fails, so callers apply their own
#   fallback. Items that failed individually are null in .data, and items whose
#   whole chunk failed are absent, which callers read as null too.
#
# Exits non-zero with a message on stderr, and nothing on stdout, when GitHub
# reports its GraphQL rate limit exhausted. Returning the surviving chunks there
# would look to callers like the missing items no longer exist.
#
# Environment:
#   BATCH_ITEM_CHUNK_SIZE - items per query (default 50). A few hundred items in
#                           one query costs the entire hourly point budget.

set -euo pipefail

pr_fields="${1:?pr_fields required}"
issue_fields="${2:?issue_fields required}"
chunk_size="${BATCH_ITEM_CHUNK_SIZE:-50}"

items="$(cat)"

count=$(echo "$items" | jq 'length')
if [[ "$count" -eq 0 ]]; then
  exit 0
fi

# owner/repo are escaped with @json so a malformed value can't break out of
# the query string; number is a jq number, emitted as bare digits.
build_query() {
  local chunk="$1" offset="$2"
  echo "$chunk" | jq -r --arg pr "$pr_fields" --arg issue "$issue_fields" --argjson offset "$offset" '
    [to_entries[] |
      ($offset + .key) as $i | .value as $it |
      "item_\($i): repository(owner: \($it.owner | @json), name: \($it.repo | @json)) { " +
      (if $it.type == "PullRequest" then
         "pullRequest(number: \($it.number)) { \($pr) }"
       else
         "issue(number: \($it.number)) { \($issue) }"
       end) + " }"
    ] | "query { " + join(" ") + " }"
  '
}

# An exhausted point budget arrives either as a RATE_LIMITED error in the body
# or as a 403 whose message gh forwards on stderr.
is_rate_limited() {
  local response="$1" stderr="$2"
  jq -e 'any(.errors[]?; .type == "RATE_LIMITED" or ((.message // "") | test("rate limit"; "i")))' \
    <<<"$response" >/dev/null 2>&1 && return 0
  grep -qi "rate limit" <<<"$stderr"
}

stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"' EXIT

chunk_data=()
offset=0

while [[ "$offset" -lt "$count" ]]; do
  query=$(build_query \
    "$(echo "$items" | jq --argjson off "$offset" --argjson size "$chunk_size" '.[$off:$off + $size]')" \
    "$offset")

  # gh exits non-zero for any response carrying .errors, including partial
  # successes that still hold usable .data, so decide from the body.
  response=$(gh api graphql -f query="$query" 2>"$stderr_file") || true

  if is_rate_limited "$response" "$(cat "$stderr_file")"; then
    echo "Error: GitHub's GraphQL rate limit is exhausted, so items $offset onward are unresolved." >&2
    echo "Check when it resets: gh api rate_limit --jq .resources.graphql" >&2
    exit 1
  fi

  data=$(jq -c '.data | select(. != null)' <<<"$response" 2>/dev/null) || data=""
  if [[ -n "$data" ]]; then
    chunk_data+=("$data")
  fi

  offset=$((offset + chunk_size))
done

if [[ "${#chunk_data[@]}" -eq 0 ]]; then
  exit 0
fi

printf '%s\n' "${chunk_data[@]}" | jq -s '{data: add}'
