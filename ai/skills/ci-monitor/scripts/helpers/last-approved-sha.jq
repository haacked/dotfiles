# last-approved-sha.jq - Head sha of the most recent run that already ran for a
# fork PR's head branch (the last state CI was let through on).
#
# Input (stdin): a GitHub "list workflow runs" response, { workflow_runs: [...] }.
# Arg $fork: the fork owner login, to disambiguate same-named branches from
# other forks.
# Output: the head_sha string, or "" when no such run exists.
#
# A gated run sits at conclusion == "action_required"; any run past that state
# was let through. The signal is "ran before", not "was deliberately approved" -
# the caller only trusts this sha by comparing content signatures against it, so
# a stale or over-broad pick can only fail closed, never auto-approve new code.
# The runs API returns newest first, so `first` is the most recent.
[ .workflow_runs[]
  | select(.head_repository.owner.login == $fork)
  | select(.status == "completed" or .status == "in_progress")
  | select((.conclusion // "") != "action_required") ]
| first | .head_sha // ""
