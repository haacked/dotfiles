# review-filter.jq - Discovery filter for review-all-prs.sh.
#
# Variables (pass via --arg / --argjson):
#   $user             - GitHub username
#   $include_reviewed - bool; if true, skip the new-commits gate
#   $team_members     - array of GitHub logins whose PRs get top priority
#
# Keeps PRs the user hasn't reviewed and PRs with commits newer than the
# user's last review. PENDING (draft) reviews have null submittedAt, so fall
# back to createdAt for the comparison.
#
# Each PR gets a priority tier:
#   1 - authored by a member of $team_members
#   2 - conventional-commit title scoped to flags (e.g. "feat(flags):",
#       "chore(feature-flags):")
#   3 - everything else
# Output is sorted by priority, then most recently updated within each tier.

map(
  (.reviews.nodes | map(select(.author.login == $user)) | last) as $last_review
  | (if $last_review == null then null
     else ($last_review.submittedAt // $last_review.createdAt) end) as $last_review_at
  | select($include_reviewed
          or $last_review_at == null
          or .commits.nodes[0].commit.committedDate > $last_review_at)
  | {
      number: .number,
      title: .title,
      url: .url,
      repo: .repository.nameWithOwner,
      author: .author.login,
      updated_at: .updatedAt,
      user_review_state: $last_review.state,
      priority: (
        .author.login as $pr_author
        | if ($team_members | index($pr_author)) then 1
          elif (.title | test("^[a-zA-Z]+\\([^)]*\\bflags\\b[^)]*\\)!?:"; "i")) then 2
          else 3
          end
      )
    }
)
| group_by(.priority)
| map(sort_by(.updated_at) | reverse)
| add // []
