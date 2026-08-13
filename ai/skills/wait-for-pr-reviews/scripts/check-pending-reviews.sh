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
#   - Requested bot reviewers (Copilot, Greptile, …): GitHub clears a *user*
#     entry from requested_reviewers when its review is submitted, so any bot
#     still listed is mid-review. Team entries linger until a human member
#     reviews, which a bot never satisfies, so teams are excluded.
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

requested_users=$(gh api "repos/${REPO}/pulls/${PR_NUMBER}/requested_reviewers" \
  --jq '[.users[]? | {login: (.login // ""), type: (.type // "")}]' 2>/dev/null) \
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
