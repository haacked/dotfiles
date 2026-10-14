# Builds the bin/triage-bot-pr-queue output from the triage-bot-pr-scope.jq
# output.
#
# $roster: the team's reviewer logins, or null when the roster fetch failed.
# $team: the team to request when no roster member qualifies.
# $details: one {number, timeline: [{event, state, login, type}],
#   commits: [{login, type}]} object per in-scope PR whose fetch succeeded.
# $committers: one {dir, logins} object per directory, one login per commit.
# $load: one {login: open review requests} object per roster member whose
#   count fetch succeeded.
# $owners: a one-element array holding the owners_yaml resolver output for
#   every in-scope path, or null when no resolver ran.
# $now: the current time in epoch seconds.

include "flags-domain";

INDEX($details[]; .number) as $details_by_number
| INDEX($committers[]; .dir) as $committers_by_dir
| ($load | add // {}) as $load
| $owners[0] as $owner_map
| def on_team: IN(($roster // [])[]);
  def human: bot_account | not;
  # An approval or a change request settles review. A comment, or an approval
  # someone dismissed, does not.
  def settles: .state | IN("approved", "changes_requested");
  def details: $details_by_number[.number | tostring];
  def owners_of($path):
    $owner_map[$path] as $r
    | if $r == null then [] elif ($r.owners | length) > 0 then $r.owners else ($r.added.additions // []) end;
  # Titles are bot-written. A pipe or newline would break the skill's markdown
  # table. A markdown link or image would render.
  def plain_text: gsub("\\s*[|\r\n]+\\s*"; " ") | gsub("!?\\[(?<text>[^\\]]*)\\]\\([^)]*\\)"; "\(.text)");
  def commits_by($login; $committers): [$committers[] | select(.login == $login) | .commits] | add // 0;

  # Input: a summary. Everyone behind the PR counts as its author, so the
  # proposal is the roster member outside humans with the most commits, then
  # the one with the lowest load.
  def proposal:
    .committers as $committers
    | [.humans[].login] as $behind
    | if $roster == null then {reviewer: $team, reason: "team roster unavailable"}
      else
        [ $roster[] | select(IN($behind[]) | not)
          | {login: ., commits: commits_by(.; $committers), load: ($load[.] // 0)} ]
        | if length == 0 then {reviewer: $team, reason: "every team member is behind this PR"}
          else
            min_by([-.commits, .load, .login])
            | {reviewer: .login,
               reason: (if .commits > 0 then "\(.commits) commits in these flags directories in 180 days"
                        else "no team commits in these paths; lowest review load (\(.load))" end)}
          end
      end;

  def summarize($d):
    [$d.timeline[] | select(.event == "reviewed")] as $reviews
    | [$reviews[] | select(human)] as $human_reviews
    | {
        number,
        title: (.title | plain_text),
        bot,
        ageDays: ((($now - (.createdAt | fromdateiso8601)) / 86400) | floor),
        stale: any(.labels[]; . == "stale"),
        labels,
        botApproved: any($reviews[]; (human | not) and .state == "approved"),
        humans: (
          [ (.assignees[] | {login: ., via: "assignee"}),
            ($d.timeline[] | select(.event == "ready_for_review" and human) | {login, via: "marked-ready"}),
            ($d.commits[] | select(human) | {login, via: "commit"}) ]
          | group_by(.login)
          | map({login: .[0].login, via: ([.[].via] | unique), onTeam: (.[0].login | on_team)})
        ),
        flagsPaths,
        owners: (
          if $owner_map == null then null
          else [.files[] | owners_of(.) | if length == 0 then "unowned" else .[] end]
            | group_by(.) | map({(.[0]): length}) | add // {}
          end
        ),
        fileCount: (.files | length),
        committers: (
          [.dirs[] | $committers_by_dir[.].logins // [] | .[] | select(on_team)]
          | group_by(.) | map({login: .[0], commits: length}) | sort_by(-.commits)
        ),
        reviewState: (
          if any($human_reviews[]; settles) then "reviewed"
          elif ($human_reviews | length) > 0 then "commented"
          else "none" end
        ),
        commenters: ([$human_reviews[].login] | unique)
      };

  [.inScope[] | details as $d | select($d != null) | summarize($d)] as $summaries
| {
    fetched,
    capped,
    roster: $roster,
    load: $load,
    prs: [$summaries[] | select(.reviewState == "none") | del(.reviewState, .commenters) | .proposal = proposal],
    commented: [$summaries[] | select(.reviewState == "commented") | del(.reviewState)],
    reviewed: [$summaries[] | select(.reviewState == "reviewed") | .number],
    outOfScope,
    unfetched: (.unfetched + [.inScope[] | select(details == null) | .number] | sort)
  }
