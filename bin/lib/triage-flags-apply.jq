# Definitions for bin/triage-flags-apply. Load with `jq -L <this directory>`
# and `include "triage-flags-apply";`.

include "flags-domain";

def login_pattern: "^[A-Za-z0-9][A-Za-z0-9-]*$";

# Input: the helper's arguments. Output: {valid: [{kind, number, login}],
# invalid: [{arg, reason}]}, each in argument order. A number named twice
# rejects every entry that names it, because the user's approval for it is
# ambiguous.
def parse_items($team):
  [ .[]
    | . as $arg
    | (capture("^(?<kind>[^:]*):(?<number>[^=]*)=(?<login>.*)$") // null) as $m
    | if $m == null then {arg: $arg, reason: "expected pr:NUMBER=LOGIN or issue:NUMBER=LOGIN"}
      elif ($m.kind | IN("pr", "issue") | not) then {arg: $arg, reason: "kind must be pr or issue"}
      elif ($m.number | test("^[1-9][0-9]*$") | not) then {arg: $arg, reason: "number must be a positive integer"}
      else
        ($m.login | ltrimstr("@")) as $login
        | if $login == $team then
            if $m.kind == "pr" then {arg: $arg, kind: $m.kind, number: ($m.number | tonumber), login: $login}
            else {arg: $arg, reason: "an issue cannot be assigned to a team"}
            end
          elif ($login | test(login_pattern)) then {arg: $arg, kind: $m.kind, number: ($m.number | tonumber), login: $login}
          else {arg: $arg, reason: "login must match \(login_pattern) or be \($team)"}
          end
      end
  ] as $parsed
  | ([$parsed[] | .number // empty] | group_by(.) | map(select(length > 1)[0])) as $repeated
  | [ $parsed[]
      | if .reason == null and (.number | IN($repeated[])) then {arg, reason: "number \(.number) appears more than once"} else . end
    ] as $checked
  | {
      valid: [$checked[] | select(.reason == null) | {kind, number, login}],
      invalid: [$checked[] | select(.reason != null)]
    };

# Input: the `gh pr view` object. $reviews: the PR's REST reviews as
# {login, type, state}. Output: why the request must not go ahead, or null.
# An approval or a change request from any human settles review, including
# from the person behind the PR.
def pr_skip_reason($reviews):
  [$reviews[] | select((bot_account | not) and (.state | IN("APPROVED", "CHANGES_REQUESTED"))) | .login] as $reviewers
  | if .state != "OPEN" then "the PR is \(.state | ascii_downcase)"
    elif .isDraft then "the PR is a draft"
    elif (.reviewRequests | length) > 0 then
      "review already requested from \([.reviewRequests[] | .login // .slug // .name] | join(", "))"
    elif ($reviewers | length) > 0 then "already reviewed by \($reviewers | unique | join(", "))"
    else null
    end;

# Input: the `gh issue view` object. Output: why the assignment must not go
# ahead, or null.
def issue_skip_reason:
  if .state != "OPEN" then "the issue is \(.state | ascii_downcase)"
  elif (.assignees | length) > 0 then "already assigned to \([.assignees[].login] | join(", "))"
  else null
  end;

# Input: one {kind, number, login, outcome, reason, status, title, url} object
# per valid item, where outcome is applied, wouldApply, skipped, or failed.
# $invalid: the parse_items rejections. $names: one {login: name} object per
# profile lookup that succeeded. Output: the helper's output object, with PRs
# before issues in each list, each by number.
def apply_output($invalid; $names; $date; $dry_run):
  ($names | add // {}) as $names
  | (map(.title |= (if . == null then null else plain_text end)) | sort_by([.kind == "issue", .number])) as $items
  | def listed($outcome): [$items[] | select(.outcome == $outcome)];
    def entries($outcome): [listed($outcome)[] | {kind, number, login, title, url}];
    def by_number($kind): [.[] | select(.kind == $kind) | {number, title, url}] | sort_by(.number);
  {
    dryRun: $dry_run,
    applied: entries("applied"),
    wouldApply: entries("wouldApply"),
    skipped: [listed("skipped")[] | {kind, number, login, reason}],
    failed: [listed("failed")[] | {kind, number, login, status, error: .reason}],
    invalid: $invalid,
    report: {
      date: $date,
      people: (
        listed(if $dry_run then "wouldApply" else "applied" end)
        | group_by(.login)
        | map({
            login: .[0].login,
            name: ($names[.[0].login] | if . == null or . == "" then null else plain_text end),
            reviews: by_number("pr"),
            issues: by_number("issue")
          })
        | sort_by(.login | ascii_downcase)
      )
    }
  };
