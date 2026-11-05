#!/bin/bash
# Run every lookup that decides which PRs the standup notes list, and print
# the results as one JSON object.
#
# Usage: standup-gather.sh <last_standup_date>
#
# The merge cutoff is the previous notes file's modified time, or
# <last_standup_date> when no previous notes exist. The carry-over PRs are the
# PR URLs in the previous notes' "Working on:" section.
#
# Output keys:
#   cutoff           the merge cutoff the searches used
#   merged_authored  my PRs merged since the cutoff
#   agent_authored   bot-authored PRs merged since the cutoff that I merged or approved
#   shepherded       other people's PRs merged since the cutoff that I merged or
#                    approved, minus feature-flags teammates' PRs
#   open             my open PRs updated since <last_standup_date>, each with
#                    review_requests
#   carry_over       url, state, and merged_at of each carry-over PR
#   must_list        the URLs the notes must contain
#
# must_list holds the merged PRs and the merged carry-over PRs. The next run's
# cutoff skips them, so notes that leave one out lose it for good. Open PRs are
# not in it, because the next run finds them again.
#
# On success the object also goes to gather.json, with the standup-find.sh row
# that set the cutoff. standup-save.sh requires that file and that row. The
# script deletes gather.json before its first lookup, so a failed lookup leaves
# no gather.json behind.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/state.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: standup-gather.sh <last_standup_date>" >&2
  exit 64
fi

last_standup_date="$1"
rm -f "$STANDUP_GATHER"

find_row=$("${SCRIPT_DIR}/standup-find.sh")
IFS=$'\t' read -r status previous _ posted_at <<<"$find_row"

cutoff="$last_standup_date"
carry_urls=""
if [[ "$status" == found ]]; then
  cutoff="$posted_at"
  carry_urls=$(awk '/^Working on:$/ { f = 1; next } f && /^$/ { exit } f' "$previous" |
    { grep -oE 'https://github\.com/[^/[:space:]]+/[^/[:space:]]+/pull/[0-9]+' || true; } | sort -u)
fi

search() {
  "${SCRIPT_DIR}/standup-search.sh" "$1" | jq -s .
}

# lookup <fields> <filter> <urls, one per line>
# Prints a JSON object that maps each URL to the filter's result.
lookup() {
  if [[ -z "$3" ]]; then
    echo '{}'
    return
  fi
  # shellcheck disable=SC2086 # The URLs hold no spaces or glob characters.
  "${SCRIPT_DIR}/standup-pr-view.sh" "$1" "$2 | tojson" $3 |
    jq -Rn '[inputs | split("\t") | {key: .[0], value: (.[1] | fromjson)}] | from_entries'
}

merged_authored=$(search "author:haacked org:PostHog is:pr is:merged merged:>=${cutoff}")
# involves: misses a PR I only reviewed. reviewed-by: misses a PR I only merged
# or commented on. The candidates are the union of both.
involved=$(search "org:PostHog is:pr is:merged merged:>=${cutoff} involves:haacked -author:haacked")
reviewed=$(search "org:PostHog is:pr is:merged merged:>=${cutoff} reviewed-by:haacked -author:haacked")
open=$(search "author:haacked org:PostHog is:pr is:open")

candidates=$(jq -s 'add | unique_by(.url)' <<<"${involved}${reviewed}")

# Repos behind a merge queue record the queue bot as the merger. An APPROVED
# review from me therefore also counts as landing the PR.
verdicts=$(lookup mergedBy,reviews \
  '{merged_by: (.mergedBy.login // ""), approved: any(.reviews[]; .author.login == "haacked" and .state == "APPROVED")}' \
  "$(jq -r '.[].url' <<<"$candidates")")
kept=$(jq --argjson v "$verdicts" '
  map(select($v[.url] | .merged_by == "haacked" or .approved) | .bot = (.author | endswith("[bot]")))
  | {bots: map(select(.bot) | del(.bot)), humans: map(select(.bot | not) | del(.bot))}' <<<"$candidates")

roster='[]'
if jq -e '.humans | length > 0' <<<"$kept" > /dev/null; then
  roster=$(gh api orgs/PostHog/teams/team-feature-flags/members --paginate --jq '.[].login' | jq -Rn '[inputs]') || {
    echo "Error: the feature-flags team roster call failed. It needs a token with read:org scope." >&2
    exit 1
  }
fi

requests=$(lookup reviewRequests '[.reviewRequests[] | .login // .slug // .name]' \
  "$(jq -r '.[] | select(.draft | not) | .url' <<<"$open")")
carry=$(lookup state,mergedAt '{state, merged_at: .mergedAt}' "$carry_urls")

result=$(jq -n --arg cutoff "$cutoff" --arg last "$last_standup_date" --argjson merged "$merged_authored" \
  --argjson kept "$kept" --argjson roster "$roster" --argjson open "$open" --argjson requests "$requests" \
  --argjson carry "$carry" '
  $kept.bots as $agent
  | ($kept.humans | map(select(.author | IN($roster[]) | not))) as $shepherded
  | ($carry | to_entries | map({url: .key} + .value)) as $carry_over
  | {
      cutoff: $cutoff,
      merged_authored: $merged,
      agent_authored: $agent,
      shepherded: $shepherded,
      open: ($open | map(select(.updated_at >= $last) | . + {review_requests: ($requests[.url] // [])})),
      carry_over: $carry_over,
      must_list: ([($merged + $agent + $shepherded)[].url, ($carry_over[] | select(.state == "MERGED") | .url)] | unique)
    }')

mkdir -p "$(dirname "$STANDUP_GATHER")"
jq --arg basis "$find_row" '. + {basis: $basis}' <<<"$result" > "${STANDUP_GATHER}.tmp"
mv "${STANDUP_GATHER}.tmp" "$STANDUP_GATHER"

echo "$result"
