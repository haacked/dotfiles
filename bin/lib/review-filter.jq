# review-filter.jq - Discovery filter for review-all-prs.sh.
#
# Variables (pass via --arg / --argjson):
#   $user             - GitHub username
#   $include_reviewed - bool; if true, skip the new-commits gate
#   $team_members     - array of GitHub logins whose PRs get top priority
#   $org_members      - array of GitHub logins who belong to the org
#   $sort_key         - within-tier sort: priority|repo|status|number
#   $sort_dir         - sort direction: asc|desc
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
# Output is grouped by priority tier. Within each tier the default order is
# most recently updated first; $sort_key/$sort_dir override that ordering.

# Rank for sorting by review status, needs-attention first. The same set of
# states is mapped to display labels in review-all-prs.sh; keep them in sync.
def status_rank:
  {
    "NONE": 0,            # no review from the user yet
    "PENDING": 1,         # unsubmitted draft review
    "CHANGES_REQUESTED": 2,
    "COMMENTED": 3,
    "APPROVED": 4,
    "DISMISSED": 5
  }[. // "NONE"] // 6;

# Apply the chosen within-tier sort to an array of PRs. The default order
# (updated, most recent first) is the stable base, so PRs that tie on the
# sort key stay newest-first. Descending numeric sorts negate the key to keep
# that tie order; repo (a string) reverses repo groups while preserving each
# group's newest-first order.
def apply_sort:
  (sort_by(.updated_at) | reverse)
  | if $sort_key == "number" then
      (if $sort_dir == "desc" then sort_by(.number * -1) else sort_by(.number) end)
    elif $sort_key == "status" then
      (if $sort_dir == "desc" then sort_by(.user_review_state | status_rank | . * -1)
       else sort_by(.user_review_state | status_rank) end)
    elif $sort_key == "repo" then
      (if $sort_dir == "desc" then (group_by(.repo) | reverse | add) else sort_by(.repo) end)
    else .   # "priority": no-op within a constant-priority tier
    end;

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
      is_org_member: (.author.login as $a | ($org_members | index($a)) != null),
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
| map(apply_sort)
| add // []
