# review-filter.jq - Discovery filter for review-all-prs.sh.
#
# Variables (pass via --arg / --argjson):
#   $user             - GitHub username
#   $include_reviewed - bool; if true, skip the new-commits gate
#   $team_members     - array of GitHub logins whose PRs get top priority
#   $org_members      - array of GitHub logins who belong to the org
#   $sort_specs       - array of {key, dir} sort pairs, highest precedence first.
#                       key is priority|repo|status|number; dir is asc|desc.
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
# Output is ordered by $sort_specs in precedence order, then the priority tier,
# then recency (most recently updated first) as always-appended tiebreakers. The
# default spec is [] (just the tiebreakers), which yields priority-tier grouping.

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

# Stably order an array of PRs by one sort key. Since jq's sort_by is stable,
# PRs that tie on the key keep their incoming order, so chaining these calls
# least-significant key first builds a multi-key sort. Descending numeric sorts
# negate the key to preserve the tie order; repo (a string) reverses repo groups
# while preserving each group's order.
def by_key($key; $dir):
  if $key == "number" then
    (if $dir == "desc" then sort_by(.number * -1) else sort_by(.number) end)
  elif $key == "status" then
    (if $dir == "desc" then sort_by(.user_review_state | status_rank | . * -1)
     else sort_by(.user_review_state | status_rank) end)
  elif $key == "repo" then
    (if $dir == "desc" then (group_by(.repo) | reverse | add) else sort_by(.repo) end)
  elif $key == "priority" then
    (if $dir == "desc" then sort_by(.priority * -1) else sort_by(.priority) end)
  else error("unknown sort key: \($key)")
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
# Apply the sort keys as a chain of stable sorts. The priority tier is appended
# as a final tiebreaker (so flags PRs surface within each group) and recency is
# the base. jq's sort_by is stable, so applying least-significant first — recency,
# then the specs in reverse (priority last in the list, so applied first) — leaves
# the first requested spec dominant.
| (sort_by(.updated_at) | reverse)
| reduce (($sort_specs + [{key: "priority", dir: "asc"}]) | reverse | .[]) as $s
    (.; by_key($s.key; $s.dir))
