# Builds the bin/triage-issue-queue output.
#
# Input: the `gh issue list` results array.
# $members: every team-feature-flags login, or null when the roster fetch
#   failed.
# $roster: the members who review code, or null.
# $committers: one {path, logins} object per area path whose fetch succeeded,
#   one login per commit.
# $load: one {login: open assigned issues} object per roster member whose
#   count fetch succeeded.
# $limit: the --limit the search ran with.
# $committer_days: how many days of commits $committers covers.
# $now: the current time in epoch seconds.

include "flags-domain";

INDEX($committers[]; .path) as $committers_by_path
| ($load | add // {}) as $load
| def team_filed: .author.login | IN(($members // [])[]);
  # Input: commit counts per login.
  def proposal(reason):
    if $roster == null then {reviewer: null, reason: "team roster unavailable"}
    else
      . as $counts
      | $roster | propose($counts; $load; reason)
      // {reviewer: null, reason: "team roster is empty"}
    end;

  [.[] | select(any(.labels[].name; IN(flags_labels[])))] as $flagged
| {
    fetched: length,
    capped: (length >= $limit),
    roster: $roster,
    issues: (
      [ $flagged[] | select(team_filed | not)
        | {number, title: (.title | plain_text), author: .author.login, ageDays: age_days($now), labels: [.labels[].name]} ]
      | sort_by(.number)
    ),
    teamFiled: ([$flagged[] | select(team_filed)] | length),
    areas: (
      reduce flags_areas[] as $area ({};
        .[$area.name] = {
          paths: $area.paths,
          proposal: (commit_counts($area.paths; $committers_by_path)
            | proposal(commit_reason($area.name; $committer_days; "fewest open assigned issues";
                history_gaps($area.paths; $committers_by_path) | length == 0)))
        })
    ),
    fallback: ({} | proposal("no code area fits; \(load_reason("fewest open assigned issues"))")),
    historyUnavailable: history_gaps([flags_areas[].paths[]]; $committers_by_path)
  }
