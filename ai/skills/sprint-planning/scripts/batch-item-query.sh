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
#   the input is empty. Items that failed individually are null in .data, and
#   items whose whole chunk failed are absent, which callers read as null too.
#
# Exit codes, both with a message on stderr and nothing on stdout:
#   1 - GitHub's GraphQL rate limit is exhausted. Returning the surviving chunks
#       would look to callers like the missing items no longer exist.
#   2 - No chunk resolved, so the query failed outright. A total failure is not
#       the same answer as an empty board, which is what exiting 0 here would
#       have said. Callers that would rather report what they know than stop can
#       degrade on this code specifically; 1 is not safe to degrade past.

set -euo pipefail

# Items per query. Chunking bounds the blast radius: a query that fails or times
# out costs one chunk rather than every item, which is what lets the surviving
# chunks still be returned. The callers that exceed one chunk are
# fetch-approved-prs.sh, which searches at --limit 100, and archive-done-items.sh,
# whose Done column has no upper bound.
chunk_size=50

pr_fields="${1:?pr_fields required}"
issue_fields="${2:?issue_fields required}"
# The loop below reads one query per line, so a newline in a selection set would
# split a query in half. They are whitespace to GraphQL, so flatten them.
pr_fields="${pr_fields//$'\n'/ }"
issue_fields="${issue_fields//$'\n'/ }"

items="$(cat)"

count=$(echo "$items" | jq 'length')
if [[ "$count" -eq 0 ]]; then
  exit 0
fi

# One query per chunk, each a single line so the loop below can read them one at
# a time. Aliases are numbered over the whole input before it is sliced, which is
# what keeps item_<index> meaningful to callers joining by index.
#
# owner/repo are escaped with @json so a malformed value can't break out of
# the query string; number is a jq number, emitted as bare digits.
queries=$(echo "$items" | jq -r --arg pr "$pr_fields" --arg issue "$issue_fields" --argjson size "$chunk_size" '
  [to_entries[] |
    .key as $i | .value as $it |
    "item_\($i): repository(owner: \($it.owner | @json), name: \($it.repo | @json)) { " +
    (if $it.type == "PullRequest" then
       "pullRequest(number: \($it.number)) { \($pr) }"
     else
       "issue(number: \($it.number)) { \($issue) }"
     end) + " }"
  ] as $fields |
  range(0; $fields | length; $size) |
  "query { " + ($fields[. : . + $size] | join(" ")) + " }"
')

# The primary point budget arrives as a RATE_LIMITED entry under .errors. A
# secondary limit is an HTTP 403 whose body is a bare {"message": ...} with no
# .errors array, so both shapes are checked. gh writes either body to stdout and
# echoes only a one-line summary to stderr, which the grep catches in case a
# future gh stops forwarding the body.
is_rate_limited() {
  local response="$1" stderr_path="$2"
  jq -e '
    any(.errors[]?; .type == "RATE_LIMITED" or ((.message // "") | test("rate limit"; "i")))
    or ((.message // "") | test("rate limit"; "i"))
  ' <<<"$response" >/dev/null 2>&1 && return 0
  grep -qi "rate limit" "$stderr_path"
}

stderr_file=$(mktemp)
trap 'rm -f "$stderr_file"' EXIT

chunk_data=()
lost=()
offset=0

while IFS= read -r query; do
  # gh exits non-zero for any response carrying .errors, including partial
  # successes that still hold usable .data, so decide from the body.
  response=$(gh api graphql -f query="$query" 2>"$stderr_file") || true

  if is_rate_limited "$response" "$stderr_file"; then
    echo "Error: GitHub's GraphQL rate limit is exhausted, so items $offset onward are unresolved." >&2
    echo "Check when it resets: gh api rate_limit --jq .resources.graphql" >&2
    exit 1
  fi

  data=$(jq -c '.data | select(. != null)' <<<"$response" 2>/dev/null) || data=""
  if [[ -n "$data" ]]; then
    chunk_data+=("$data")
  else
    # Held until the end: if every chunk fails the error below covers them all,
    # and a per-chunk warning for each would just repeat it.
    last=$(( offset + chunk_size < count ? offset + chunk_size - 1 : count - 1 ))
    lost+=("items $offset to $last")
  fi

  offset=$((offset + chunk_size))
done <<<"$queries"

# The input was non-empty, so nothing resolving means the query failed outright
# rather than the board being empty. Those read the same to a caller that only
# checks for empty output, which is how an expired token becomes "no work".
if [[ "${#chunk_data[@]}" -eq 0 ]]; then
  echo "Error: none of the $count items resolved; the GraphQL query failed for every chunk." >&2
  echo "Check that gh is authenticated: gh auth status" >&2
  exit 2
fi

# Some items resolved and some did not. Callers read the missing ones as null,
# the same as items that failed on their own, so name them rather than let them
# vanish quietly.
if [[ "${#lost[@]}" -gt 0 ]]; then
  for range in "${lost[@]}"; do
    echo "Warning: $range did not resolve." >&2
  done
fi

printf '%s\n' "${chunk_data[@]}" | jq -s '{data: add}'
