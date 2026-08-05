# pending-filter.jq - Keep only PRs whose last review by $user is an
# unsubmitted PENDING draft.
#
# review-all-prs.sh uses this to pre-filter the involves:@me discovery sweep:
# involves: also matches PRs you merely commented on or were mentioned in,
# which would otherwise flood the listing through the unreviewed-PR gate.
#
# Variables: $user - GitHub username
#
# The last-user-review selection is duplicated in review-filter.jq; keep in sync.
[.[] | select(((.reviews.nodes // []) | map(select(.author.login == $user)) | last | .state) == "PENDING")]
