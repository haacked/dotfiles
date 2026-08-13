# quarantine-state.jq - Pure parse of a Trunk Test Analytics comment.
#
# Trunk's flaky-test quarantining masks a quarantined test's failure so it
# cannot fail a required check. The analytics comment Trunk keeps on each PR
# carries shields.io badges whose labels hold the failed and quarantined test
# counts for one commit (`badge/<N>-failed-…`, `badge/<N>-quarantined-…`,
# with a `commitHash=` on their links). This extracts the numbers and nothing
# else; what a reading means for a given eviction stays with the caller.
# Fails closed: a missing comment or badge reads as readable:false, never as
# a count.
#
# Input (stdin), one object: { body: <string|null>, updated_at: <string|null> }
# Output: { readable, failed, quarantined, commit, updated_at }
#   commit is the hash the badge links carry, so a caller can tell a current
#   reading from one describing an older attempt.

(.body // "") as $body
| ([$body | capture("badge/(?<n>[0-9]+)-failed-")][0].n) as $failed
| ([$body | capture("badge/(?<n>[0-9]+)-quarantined-")][0].n) as $quarantined
| ([$body | capture("commitHash=(?<h>[0-9a-fA-F]{7,40})")][0].h) as $commit
| {
    readable: ($failed != null and $quarantined != null),
    failed: ($failed | if . == null then null else tonumber end),
    quarantined: ($quarantined | if . == null then null else tonumber end),
    commit: $commit,
    updated_at: (.updated_at // null)
  }
