# Splits `gh search prs` results into internal and external PRs for
# bin/triage-flags-pr-candidates. It drops bots and external drafts.
#
# Input: the search results array.
# $limit: the --limit the search ran with.
# Output: {fetched, capped, prs: [{number, title, author, labels, isDraft, internal}]}

# gh reports is_bot false for app accounts. The type field identifies them.
# Some bots are user accounts, which only the login pattern catches.
def bot:
  .author.type == "Bot"
  or (.author.login | test("\\[bot\\]|^posthog-bot$|dependabot|github-actions"));

def internal: .authorAssociation | IN("MEMBER", "OWNER", "COLLABORATOR");

{
  fetched: length,
  capped: (length >= $limit),
  prs: (
    [ .[]
      | select(bot | not)
      | internal as $internal
      | select($internal or (.isDraft | not))
      | {number, title, author: .author.login, labels: [.labels[].name], isDraft, internal: $internal}
    ]
    | sort_by(.number)
  )
}
