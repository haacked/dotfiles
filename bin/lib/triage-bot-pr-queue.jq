# Builds the bin/triage-bot-pr-queue output from the triage-bot-pr-scope.jq
# output.
#
# $roster: the team's reviewer logins, or null when the roster fetch failed.
# $team: the team to request when no roster member qualifies.
# $details: one {number, timeline: [{event, state, login, type}],
#   commits: [{login, type}]} object per in-scope PR whose fetch succeeded.
# $committers: one {path, logins} object per commit path whose fetch succeeded,
#   one login per commit.
# $load: one {login: open review requests} object per roster member whose
#   count fetch succeeded.
# $committer_days: how many days of commits $committers covers.
# $now: the current time in epoch seconds.

include "flags-domain";

INDEX($details[]; .number) as $details_by_number
| INDEX($committers[]; .path) as $committers_by_path
| ($load | add // {}) as $load
| def human: bot_account | not;
  # An approval or a change request settles review. A comment, or an approval
  # someone dismissed, does not.
  def settles: .state | IN("approved", "changes_requested");
  def details: $details_by_number[.number | tostring];

  # Input: an in-scope PR. Everyone behind the PR counts as its author, so the
  # proposal comes from the roster members outside humans.
  def proposal($humans):
    commit_counts(.commitPaths; $committers_by_path) as $counts
    | (history_gaps(.commitPaths; $committers_by_path) | length == 0) as $complete
    | if $roster == null then {reviewer: $team, reason: "team roster unavailable"}
      else
        [$roster[] | select(IN($humans[].login) | not)]
        | propose($counts; $load; commit_reason("these flags paths"; $committer_days; "lowest review load"; $complete))
        // {reviewer: $team, reason: "every team member is behind this PR"}
      end;

  def summarize($d):
    ( [ (.assignees[] | {login: ., via: "assignee"}),
        ($d.timeline[] | select(.event == "ready_for_review" and human) | {login, via: "marked-ready"}),
        ($d.commits[] | select(human) | {login, via: "commit"}) ]
      | group_by(.login)
      | map({login: .[0].login, via: ([.[].via] | unique)})
    ) as $humans
    | [$d.timeline[] | select(.event == "reviewed")] as $reviews
    | [$reviews[] | select(human)] as $human_reviews
    # A comment from someone behind the PR is author activity, not review.
    | [$human_reviews[] | select(.login | IN($humans[].login) | not)] as $outside_reviews
    | {
        number,
        title: (.title | plain_text),
        bot,
        ageDays: age_days($now),
        stale: any(.labels[]; . == "stale"),
        labels,
        botApproved: any($reviews[]; (human | not) and .state == "approved"),
        humans: $humans,
        flagsPaths,
        fileCount: (.files | length),
        proposal: proposal($humans),
        reviewState: (
          if any($human_reviews[]; settles) then "reviewed"
          elif ($outside_reviews | length) > 0 then "commented"
          else "none" end
        ),
        commenters: ([$outside_reviews[].login] | unique)
      };

  [.inScope[] | details as $d | select($d != null) | summarize($d)] as $summaries
| {
    fetched,
    capped,
    roster: $roster,
    prs: [$summaries[] | select(.reviewState == "none") | del(.reviewState, .commenters)],
    commented: [$summaries[] | select(.reviewState == "commented") | del(.reviewState, .proposal)],
    reviewed: [$summaries[] | select(.reviewState == "reviewed") | .number],
    outOfScope,
    unfetched: (.unfetched + [.inScope[] | select(details == null) | .number] | sort),
    historyUnavailable: history_gaps([.inScope[].commitPaths[]] | unique; $committers_by_path)
  }
