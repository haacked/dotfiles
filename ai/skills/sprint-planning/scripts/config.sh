#!/bin/bash
# Team configuration for the sprint-planning and sprint-status skills.
#
# Pick a team with SPRINT_TEAM (default "feature-flags"); the matching defaults
# below are applied. Any individual value can still be overridden by exporting
# its SPRINT_* variable before sourcing this file. Scripts source this file;
# the SKILL.md inline commands source it too.
#
# To run for the Flags Platform team instead of the default:
#
#   export SPRINT_TEAM="platform"

# GitHub org that owns the team, project board, and repositories.
SPRINT_ORG="${SPRINT_ORG:-PostHog}"

# Repository holding the sprint issues and where the update is posted.
SPRINT_REPO="${SPRINT_REPO:-PostHog/posthog}"

# Team selector. Each case sets that team's defaults; an explicitly exported
# SPRINT_* variable always wins via the ${VAR:-default} fallbacks.
#
# SPRINT_TEAM_SLUG       - GitHub team slug under SPRINT_ORG (members API).
# SPRINT_TEAM_NAME       - Human-readable name used in prose and prompts.
# SPRINT_PROJECT_NUMBER  - Project board number under SPRINT_ORG.
# SPRINT_GOALS_URL       - Goals page link included in the update.
# SPRINT_COMMENT_HEADER  - Heading that identifies this team's sprint comment.
#                          Matched as a whole line, so "# Team Feature Flags"
#                          does not collide with "# Team Feature Flags Platform".
case "${SPRINT_TEAM:-feature-flags}" in
  platform | flags-platform)
    SPRINT_TEAM_SLUG="${SPRINT_TEAM_SLUG:-team-flags-platform}"
    SPRINT_TEAM_NAME="${SPRINT_TEAM_NAME:-Feature Flags Platform}"
    SPRINT_PROJECT_NUMBER="${SPRINT_PROJECT_NUMBER:-170}"
    SPRINT_GOALS_URL="${SPRINT_GOALS_URL:-https://posthog.com/teams/flags-platform#goals}"
    SPRINT_COMMENT_HEADER="${SPRINT_COMMENT_HEADER:-# Team Feature Flags Platform}"
    ;;
  *)
    SPRINT_TEAM_SLUG="${SPRINT_TEAM_SLUG:-team-feature-flags}"
    SPRINT_TEAM_NAME="${SPRINT_TEAM_NAME:-Feature Flags}"
    SPRINT_PROJECT_NUMBER="${SPRINT_PROJECT_NUMBER:-112}"
    SPRINT_GOALS_URL="${SPRINT_GOALS_URL:-https://posthog.com/teams/feature-flags#goals}"
    SPRINT_COMMENT_HEADER="${SPRINT_COMMENT_HEADER:-# Team Feature Flags}"
    ;;
esac

# Space-separated GitHub handles used only if the members API call fails.
# Leave empty to fall back to asking the user.
SPRINT_FALLBACK_MEMBERS="${SPRINT_FALLBACK_MEMBERS:-}"
