#!/bin/bash
# Team configuration for the quarterly-planning skill.
#
# Pick a team with QPLAN_TEAM (default "feature-flags"); the matching defaults
# below are applied. Any individual value can still be overridden by exporting
# its QPLAN_* variable before sourcing this file. Scripts source this file;
# the SKILL.md inline commands source it too.
#
# To run for the Flags Platform team instead of the default:
#
#   export QPLAN_TEAM="platform"

# GitHub org that owns the team and repositories.
QPLAN_ORG="${QPLAN_ORG:-PostHog}"

# Repository whose issues are mined for planning themes.
QPLAN_REPO="${QPLAN_REPO:-PostHog/posthog}"

# Team selector. Each case sets that team's defaults; an explicitly exported
# QPLAN_* variable always wins via the ${VAR:-default} fallbacks.
#
# QPLAN_TEAM_SLUG  - GitHub team slug under QPLAN_ORG (members API).
# QPLAN_TEAM_NAME  - Human-readable name used in prose and prompts.
# QPLAN_LABELS     - Space-separated issue labels to mine. Issues matching ANY
#                    label are unioned and de-duplicated. Labels that don't
#                    exist in the repo are reported and skipped, not fatal.
# QPLAN_GOALS_URL  - Team goals page (last quarter's goals live here).
case "${QPLAN_TEAM:-feature-flags}" in
  platform | flags-platform)
    QPLAN_TEAM_SLUG="${QPLAN_TEAM_SLUG:-team-flags-platform}"
    QPLAN_TEAM_NAME="${QPLAN_TEAM_NAME:-Feature Flags Platform}"
    QPLAN_LABELS="${QPLAN_LABELS:-team/flags-platform feature/feature-flags}"
    QPLAN_GOALS_URL="${QPLAN_GOALS_URL:-https://posthog.com/teams/flags-platform}"
    ;;
  *)
    QPLAN_TEAM_SLUG="${QPLAN_TEAM_SLUG:-team-feature-flags}"
    QPLAN_TEAM_NAME="${QPLAN_TEAM_NAME:-Feature Flags}"
    QPLAN_LABELS="${QPLAN_LABELS:-team/feature-flags feature/feature-flags feature/cohorts feature/feature-management}"
    QPLAN_GOALS_URL="${QPLAN_GOALS_URL:-https://posthog.com/teams/feature-flags}"
    ;;
esac

# PostHog goal-setting handbook reference.
QPLAN_HANDBOOK_URL="${QPLAN_HANDBOOK_URL:-https://posthog.com/handbook/company/goal-setting}"

# Max issues fetched per label.
QPLAN_ISSUE_LIMIT="${QPLAN_ISSUE_LIMIT:-800}"
