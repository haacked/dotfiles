# checks-rollup.jq - Rebuild `gh pr checks`'s check list from the raw rollup.
#
# `gh pr checks --json name,state,bucket,link,workflow` runs its own GraphQL
# query and computes `bucket` (pass/fail/pending/skipping/cancel) from it.
# `gh pr view --json statusCheckRollup` returns the same underlying data, but
# raw: a union of CheckRun and StatusContext nodes, with conclusion/status on
# one and state on the other. This reimplements gh's bucketing
# (pkg/cmd/pr/checks/aggregate.go's aggregateChecks, verified against that
# source on 2026-09-22) against that raw shape, letting ci-monitor fold the
# checks read into the same call it already makes for head ref and fork
# status.
#
# Two things gh's checks command does that this cannot reproduce, both because
# `gh pr view --json statusCheckRollup` drops the underlying field before
# exporting that JSON (see api/export_pr.go):
#   - `event` isn't exported for CheckRun nodes. A job whose workflow fires on
#     two trigger events (e.g. both pull_request and pull_request_review) gets
#     one CheckRun node per event with the same name and workflow; gh keeps
#     both as separate entries, this keeps only whichever started more
#     recently. A push's FAILURE can therefore be hidden behind a later
#     SKIPPED from an unrelated review event, reading as 0 failures where gh
#     reads 1. Observed live only on notification-style workflows that run on
#     both events (PostHog/posthog: "Priority Review Slack Notifications",
#     "Inkeep Agent").
#   - gh's output is startedAt-descending; this does not preserve that order,
#     since nothing downstream sorts on it.
#
# Input (stdin): the raw `statusCheckRollup` array from `gh pr view --json
# statusCheckRollup`, or null when the PR has no rollup.
# Output: [{name, state, bucket, workflow, link}], deduplicated the way gh
# dedupes repeated check runs for the same commit (most recent by startedAt
# wins, keyed on StatusContext .context or CheckRun .name + .workflowName).

# CheckRun carries status (QUEUED/IN_PROGRESS/COMPLETED/WAITING/PENDING/
# REQUESTED) and, once COMPLETED, conclusion (ACTION_REQUIRED/TIMED_OUT/
# CANCELLED/FAILURE/SUCCESS/NEUTRAL/SKIPPED/STARTUP_FAILURE/STALE).
# StatusContext carries state (EXPECTED/ERROR/FAILURE/PENDING/SUCCESS)
# directly. Either way this is the same string gh buckets on and reports back
# as the check's `state`.
def state_of:
  if .__typename == "CheckRun" then
    (if .status == "COMPLETED" then (.conclusion // "") else (.status // "") end)
  else
    (.state // "")
  end;

def bucket_of($state):
  if $state == "SUCCESS" then "pass"
  elif $state == "SKIPPED" or $state == "NEUTRAL" then "skipping"
  elif $state == "ERROR" or $state == "FAILURE" or $state == "TIMED_OUT" or $state == "ACTION_REQUIRED" then "fail"
  elif $state == "CANCELLED" then "cancel"
  else "pending"
  end;

# StatusContext has no `name`, only `context`; CheckRun always has `name`.
def name_of:
  if (.name // "") != "" then .name else (.context // "") end;

# StatusContext has no `detailsUrl`, only `targetUrl`; prefer detailsUrl when
# both could apply, matching gh's fallback (empty string, not null, counts as
# absent, so this cannot use jq's `//` directly).
def link_of:
  if (.detailsUrl // "") != "" then .detailsUrl else (.targetUrl // "") end;

def dedup_key:
  if .__typename == "StatusContext" then "s:" + (.context // "")
  else "c:" + (.name // "") + "/" + (.workflowName // "")
  end;

(. // [])
| sort_by(.startedAt // "") | reverse
| reduce .[] as $item ({seen: {}, out: []};
    ($item | dedup_key) as $key
    | if (.seen[$key] // false) then .
      else .seen[$key] = true | .out += [$item]
      end)
| .out
| map(state_of as $state | {
    name: name_of,
    state: $state,
    bucket: bucket_of($state),
    workflow: (.workflowName // ""),
    link: link_of
  })
