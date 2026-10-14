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
