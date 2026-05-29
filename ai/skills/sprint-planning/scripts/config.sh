#!/bin/bash
# Team configuration for the sprint-planning skill.
#
# Every value can be overridden by exporting the matching environment variable
# before invoking the skill, or by editing the defaults below. Scripts source
# this file; the SKILL.md inline commands source it too.
#
# To run a sprint update for the Flags Platform team instead of the default,
# export these before invoking (or copy them into a wrapper):
#
#   export SPRINT_TEAM_SLUG="team-flags-platform"
#   export SPRINT_TEAM_NAME="Feature Flags Platform"
#   export SPRINT_PROJECT_NUMBER="170"
#   export SPRINT_GOALS_URL="https://posthog.com/teams/flags-platform#goals"
#   export SPRINT_COMMENT_HEADER="# Team Feature Flags Platform"

# GitHub org that owns the team, project board, and repositories.
SPRINT_ORG="${SPRINT_ORG:-PostHog}"

# Repository holding the sprint issues and where the update is posted.
SPRINT_REPO="${SPRINT_REPO:-PostHog/posthog}"

# GitHub team slug under SPRINT_ORG (used for the members API).
SPRINT_TEAM_SLUG="${SPRINT_TEAM_SLUG:-team-feature-flags}"

# Human-readable team name used in prose and prompts.
SPRINT_TEAM_NAME="${SPRINT_TEAM_NAME:-Feature Flags}"

# Project board number under SPRINT_ORG.
SPRINT_PROJECT_NUMBER="${SPRINT_PROJECT_NUMBER:-112}"

# Goals page link included in the update (leave empty to omit).
SPRINT_GOALS_URL="${SPRINT_GOALS_URL:-https://posthog.com/teams/feature-flags#goals}"

# Markdown heading that identifies this team's sprint comment. Matched as a
# whole line, so "# Team Feature Flags" will not collide with
# "# Team Feature Flags Platform".
SPRINT_COMMENT_HEADER="${SPRINT_COMMENT_HEADER:-# Team Feature Flags}"

# Space-separated GitHub handles used only if the members API call fails.
# Leave empty to fall back to asking the user.
SPRINT_FALLBACK_MEMBERS="${SPRINT_FALLBACK_MEMBERS:-}"
