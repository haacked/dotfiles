# Builds the bin/triage-flags-pr-candidates output from the
# triage-pr-classify.jq output.
#
# $details: one {number, files, reviewDecision} object per PR whose per-PR
# fetch succeeded. Internal PRs' objects carry no reviewDecision.

# The net is broad on purpose. It catches flags, cohorts, and early access
# wherever they live, including paths that CODEOWNERS does not map to the team.
def flags_path: test("feature_flag|cohort|early[-_]access|/flags/|rust/feature-flags"; "i");

INDEX($details[]; .number) as $by_number
| def fetched_details: $by_number[.number | tostring];
{
  fetched,
  capped,
  external: [
    .prs[]
    | select(.internal | not)
    | fetched_details as $d
    | {number, title, author, labels, reviewDecision: $d.reviewDecision, files: $d.files}
  ],
  internal: [
    .prs[]
    | select(.internal)
    | {number, title, author, isDraft, paths: [fetched_details.files // [] | .[] | select(flags_path)]}
    | select(.paths | length > 0)
  ],
  unfetched: [.prs[] | select(fetched_details == null) | .number]
}
