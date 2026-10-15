# Shared definitions for the Feature Flags triage helpers. Load with
# `jq -L <this directory>` and `include "flags-domain";`.

# Input: an account object with login and some of is_bot and type, from a PR
# author, a review, a timeline event, or a commit.
# `gh search prs` and the REST API report is_bot false or omit it for app
# accounts. Their type field identifies them. `gh pr list` sets is_bot and
# prefixes app logins with "app/". Some bots are user accounts, which only the
# login pattern catches.
def bot_account:
  .is_bot == true
  or .type == "Bot"
  or (.login // "" | test("\\[bot\\]|^app/|^posthog-bot$|dependabot|github-actions"));

# Input: a PR object from `gh search prs` or `gh pr list`.
def bot: .author | bot_account;

# Input: a file path.
# The net is broad on purpose. It catches flags, cohorts, and early access
# wherever they live, including paths that no owners.yaml maps to the team.
def flags_path: test("feature[-_]flag|flags[-_]|cohort|early[-_]access|/flags/"; "i");

def flags_labels: ["team/feature-flags", "feature/feature-flags", "feature/cohorts", "feature/early-access-management"];

# Input: a PR object from `gh pr list`.
# A ready bot PR with no review request is one the reviewer auto-assigner did
# not route.
def unrequested_bot_pr: bot and (.reviewRequests | length == 0);

# The code areas the team owns, for mapping an issue to the people who work on
# it. Each path is a directory or file in PostHog/posthog.
def flags_areas: [
  {name: "flag evaluation service", paths: ["rust/feature-flags", "rust/flags-consumer"]},
  {name: "feature flags app", paths: [
    "products/feature_flags", "posthog/api/services/flags_service.py", "frontend/src/scenes/feature-flags"]},
  {name: "cohort processing", paths: ["rust/cohort-core", "rust/cohort-stream-processor"]},
  {name: "cohorts app", paths: ["products/cohorts", "posthog/api/cohort.py", "frontend/src/scenes/cohorts"]},
  {name: "early access", paths: ["products/early_access_features"]}
];

# Input: bot- or human-written text such as a PR or issue title. A pipe or
# newline would break a markdown table. A markdown link or image would render.
# Angle brackets and @channel, @here, or @everyone would ping people when the
# user pastes a Slack report that quotes the title.
# The link pattern misses link text with nested brackets. A space after every
# remaining "](" stops any such link from forming, because markdown requires
# the "(" to follow the "]" directly.
def plain_text:
  gsub("\\s*[|\r\n]+\\s*"; " ")
  | gsub("!?\\[(?<text>[^\\]]*)\\]\\([^)]*\\)"; "\(.text)")
  | gsub("\\]\\("; "] (")
  | gsub("[<>]"; "")
  | gsub("@+(?<word>channel|here|everyone)\\b"; "\(.word)"; "i");

# Input: an object with createdAt.
def age_days($now): (($now - (.createdAt | fromdateiso8601)) / 86400) | floor;

# Input: paths. Replaces each path with its shortest ancestor in the list. The
# commits API already includes a directory's subdirectories, so fetching both
# would count each commit twice.
def fold_nested:
  unique as $distinct
  | map(. as $path
      | [$distinct[] | . as $ancestor | select($path | startswith($ancestor + "/"))]
      | min_by(length) // $path);

# Input: anything. Counts commits per login across $paths, given $by_path from
# INDEX over {path, logins} objects.
def commit_counts($paths; $by_path):
  reduce ($paths[] | $by_path[.].logins // [] | .[]) as $login ({}; .[$login] += 1);

# The paths in $paths whose commit history failed to load. A failed fetch
# leaves no entry in $by_path.
def history_gaps($paths; $by_path): [$paths[] | select($by_path[.] == null)];

# Input: candidate logins. $counts maps logins to commits, and $load maps
# logins to open items, with no entry when a load fetch failed. Picks the most
# commits, then the lowest known load, then the alphabetically first login.
# Output: {reviewer, reason} with reason evaluated on the winner's
# {login, commits, load}, or null when there is no candidate.
def propose($counts; $load; reason):
  [.[] | {login: ., commits: ($counts[.] // 0), load: $load[.]}]
  | if length == 0 then null
    else min_by([-.commits, (.load // infinite), .login]) | {reviewer: .login, reason: reason}
    end;

# Input: the candidate that propose picked.
def load_reason($label): "\($label) (\(.load // "unknown"))";

# Input: the candidate that propose picked. $complete is false when some path's
# commit history failed to load, so the counts may be short.
def commit_reason($where; $days; $load_label; $complete):
  (if .commits > 0 then "\(.commits) commit\(if .commits == 1 then "" else "s" end) in \($where) in \($days) days"
   else "no team commits in \($where); \(load_reason($load_label))"
   end)
  + (if $complete then "" else "; some commit history failed to load" end);
