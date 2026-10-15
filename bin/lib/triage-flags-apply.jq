# Definitions for bin/triage-flags-apply. Load with `jq -L <this directory>`
# and `include "triage-flags-apply";`.

include "flags-domain";

def login_pattern: "^[A-Za-z0-9][A-Za-z0-9-]*$";

# Input: the helper's arguments. Output: {valid: [{kind, number, login}],
# invalid: [{arg, reason}]}, each in argument order. A number named twice
# rejects every entry that names it, because the user's approval for it is
# ambiguous. GitHub logins ignore case, so user logins are lowercased.
def parse_items($team):
  [ .[]
    | . as $arg
    | (capture("^(?<kind>[^:]*):(?<number>[^=]*)=(?<login>.*)$") // null) as $m
    | ($m.number // "" | if test("^[1-9][0-9]*$") then tonumber else null end) as $number
    | ($m.login // "" | ltrimstr("@")) as $login
    | {arg: $arg, number: $number}
    + if $m == null then {reason: "expected pr:NUMBER=LOGIN or issue:NUMBER=LOGIN"}
      elif ($m.kind | IN("pr", "issue") | not) then {reason: "kind must be pr or issue"}
      elif $number == null then {reason: "number must be a positive integer"}
      elif $login == $team then
        if $m.kind == "pr" then {kind: $m.kind, login: $login}
        else {reason: "an issue cannot be assigned to a team"}
        end
      elif ($login | test(login_pattern)) then {kind: $m.kind, login: ($login | ascii_downcase)}
      else {reason: "login must match \(login_pattern) or be \($team)"}
      end
  ] as $parsed
  | ([$parsed[] | .number // empty] | group_by(.) | map(select(length > 1)[0])) as $repeated
  | [ $parsed[]
      | if .reason == null and (.number | IN($repeated[])) then .reason = "number \(.number) appears more than once" else . end
    ] as $checked
  | {
      valid: [$checked[] | select(.reason == null) | {kind, number, login}],
      invalid: [$checked[] | select(.reason != null) | {arg, reason}]
    };

# Input: the `gh pr view` object. $reviews: the PR's REST reviews as
# {login, type, state}. Output: why the request must not go ahead, or null.
# An approval or a change request from any human settles review, including
# from the person behind the PR.
def pr_skip_reason($reviews):
  [$reviews[] | select((bot_account | not) and (.state | IN("APPROVED", "CHANGES_REQUESTED"))) | .login] as $reviewers
  | if type != "object" or (.state | type) != "string" then "GitHub returned unexpected data"
    elif .state != "OPEN" then "the PR is \(.state | ascii_downcase)"
    elif .isDraft then "the PR is a draft"
    elif (.reviewRequests | length) > 0 then
      "review already requested from \([.reviewRequests[] | .login // .slug // .name] | join(", "))"
    elif ($reviewers | length) > 0 then "already reviewed by \($reviewers | unique | join(", "))"
    else null
    end;

# Input: the `gh issue view` object. Output: why the assignment must not go
# ahead, or null. `gh issue view` and `gh issue edit` also accept a PR number,
# which would bypass the PR checks.
def issue_skip_reason:
  if type != "object" or (.state | type) != "string" then "GitHub returned unexpected data"
  elif .url // "" | test("/pull/[0-9]+$") then "it is a pull request, not an issue"
  elif .state != "OPEN" then "the issue is \(.state | ascii_downcase)"
  elif (.assignees | length) > 0 then "already assigned to \([.assignees[].login] | join(", "))"
  else null
  end;

# Input: one {kind, number, login, outcome, reason, status, title, url} object
# per item that recorded an outcome, where outcome is applied, wouldApply,
# skipped, or failed. $parsed: the parse_items output. $names: one
# {login: name} object per profile lookup that succeeded. Output: the helper's
# output object, with PRs before issues in each list, each by number. A valid
# item that recorded no outcome is listed as failed, because its write may
# have happened.
def apply_output($parsed; $names; $date; $dry_run):
  ($names | add // {}) as $names
  | (map(.title |= (if . == null then null else plain_text end))) as $recorded
  | ([$recorded[] | "\(.kind):\(.number)"]) as $seen
  | ($recorded
      + [ $parsed.valid[] | select("\(.kind):\(.number)" | IN($seen[]) | not)
          | . + {outcome: "failed", reason: "no outcome recorded", status: null, title: null, url: null} ]
    | sort_by([.kind == "issue", .number])) as $items
  | def listed($outcome): [$items[] | select(.outcome == $outcome)];
    def entries($outcome): [listed($outcome)[] | {kind, number, login, title, url}];
    def by_number($kind): [.[] | select(.kind == $kind) | {number, title, url}] | sort_by(.number);
  {
    dryRun: $dry_run,
    applied: entries("applied"),
    wouldApply: entries("wouldApply"),
    skipped: [listed("skipped")[] | {kind, number, login, reason}],
    failed: [listed("failed")[] | {kind, number, login, status, error: .reason}],
    invalid: $parsed.invalid,
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
