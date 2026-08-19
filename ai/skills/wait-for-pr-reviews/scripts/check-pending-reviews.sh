#!/usr/bin/env bash
# check-pending-reviews.sh - Report which reviewers are still mid-review on a PR.
#
# Two in-flight signals, both read from structure and timestamps, never prose:
#
#   - The `reviewhog` label: ReviewHog (PostHog's review bot) runs a round when
#     the label is applied. It posts as posthog[bot] with `<!-- reviewhog: -->`
#     HTML markers on its review and status comment, and the label can linger
#     after the round completes, so "pending" means: label present AND no marked
#     completion since it was last applied (per the issue timeline).
#   - Requested bot reviewers (Copilot, Greptile, …): GitHub clears the entry
#     when the review is submitted, so any bot still requested is mid-review.
#     The list comes from GraphQL `reviewRequests`, which returns App reviewers
#     as Bot nodes; REST `requested_reviewers` omits them entirely. Team entries
#     linger until a human member reviews, which a bot never satisfies, so teams
#     are excluded.
#
# READ-ONLY: never requests a review, comments, or labels anything.
# The verdict is a pure function (helpers/pending-reviews.jq); this wrapper only
# gathers inputs - five gh invocations, three of which paginate (timeline,
# reviews, comments) at one request per 100-item page, so five requests is the
# small-PR floor and an old PR with a long history issues many more per check.
# Budget the wait loop's 30s cadence against gh's 5000/hour limit accordingly.
#
# Requires gh 2.53+ for `api --slurp`.
#
# Usage: check-pending-reviews.sh <repo> <pr_number>
#
# Output: JSON { pending: [{reviewer, signal: "label"|"requested_reviewer", since}],
#                warnings: [<string>] }
# Exit: 0 when a verdict was computed (non-empty pending is not an error),
#       1 when an input could not be fetched (message on stderr).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
source "${DOTFILES_DIR}/bin/lib/logging.sh"

PENDING_JQ="${SCRIPT_DIR}/helpers/pending-reviews.jq"

if [[ $# -lt 2 ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number>" >&2
  exit 1
fi

REPO="$1"
PR_NUMBER="$2"
REPO_OWNER="${REPO%%/*}"
REPO_NAME="${REPO#*/}"

die() {
  log_error "$1"
  exit 1
}

# Every gh fallback puts `||` outside the command substitution: `gh api` writes
# HTTP error bodies to stdout, so a fallback inside the substitution would
# capture the error body concatenated with the default - not one JSON document.

labels=$(gh api "repos/${REPO}/issues/${PR_NUMBER}" --jq '[.labels[].name]' 2>/dev/null) \
  || die "could not fetch labels for ${REPO}#${PR_NUMBER}"

# --slurp cannot be combined with --jq, so projection happens downstream. The
# timeline dates label applications and review requests; everything else on it
# is dropped here.
timeline=$(gh api --paginate --slurp \
  "repos/${REPO}/issues/${PR_NUMBER}/timeline?per_page=100" 2>/dev/null \
  | jq '[ .[][]
          | select(.event == "labeled" or .event == "review_requested")
          | { event,
              label: (.label.name // null),
              reviewer: (.requested_reviewer.login // null),
              created_at: (.created_at // null) } ]') \
  || die "could not fetch timeline for ${REPO}#${PR_NUMBER}"

reviews=$(gh api --paginate --slurp \
  "repos/${REPO}/pulls/${PR_NUMBER}/reviews?per_page=100" 2>/dev/null \
  | jq '[ .[][]
          | { login: (.user.login // ""),
              type: (.user.type // ""),
              body: (.body // ""),
              submitted_at: (.submitted_at // null) } ]') \
  || die "could not fetch reviews for ${REPO}#${PR_NUMBER}"

comments=$(gh api --paginate --slurp \
  "repos/${REPO}/issues/${PR_NUMBER}/comments?per_page=100" 2>/dev/null \
  | jq '[ .[][]
          | { login: (.user.login // ""),
              type: (.user.type // ""),
              body: (.body // ""),
              created_at: (.created_at // null),
              updated_at: (.updated_at // null) } ]') \
  || die "could not fetch comments for ${REPO}#${PR_NUMBER}"

# GraphQL, not REST: `pulls/:n/requested_reviewers` returns only `.users`, and a
# GitHub App reviewer (Copilot, Greptile) is a Bot node that never appears there,
# so the REST list reads empty while the bot is mid-review. `__typename` doubles
# as the `type` the verdict filters on. Team and Mannequin nodes are dropped here,
# which is what excludes teams: a team request lingers until a human member
# reviews, which a bot's review never satisfies.
# shellcheck disable=SC2016  # $owner/$name/$pr are GraphQL variables, not shell
requested_users=$(gh api graphql \
  -f query='query($owner: String!, $name: String!, $pr: Int!) {
      repository(owner: $owner, name: $name) {
        pullRequest(number: $pr) {
          reviewRequests(first: 100) {
            nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } } }
          }
        }
      }
    }' \
  -f owner="${REPO_OWNER}" -f name="${REPO_NAME}" -F pr="${PR_NUMBER}" \
  --jq '[.data.repository.pullRequest.reviewRequests.nodes[]?.requestedReviewer
         | select(. != null and (.__typename == "User" or .__typename == "Bot"))
         | {login: (.login // ""), type: .__typename}]' 2>/dev/null) \
  || die "could not fetch requested reviewers for ${REPO}#${PR_NUMBER}"

jq -n \
  --argjson labels "${labels}" \
  --argjson timeline "${timeline}" \
  --argjson reviews "${reviews}" \
  --argjson comments "${comments}" \
  --argjson requested_users "${requested_users}" \
  '{labels: $labels, timeline: $timeline, reviews: $reviews,
    comments: $comments, requested_users: $requested_users}' \
  | jq -f "${PENDING_JQ}"
