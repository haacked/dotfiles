#!/usr/bin/env bash
# Claude Code hook that logs workflow commands so a later session can answer
# "which steps have run against this branch?" after the context is gone.
#
# Registered on two events, because both paths are common: UserPromptSubmit
# catches a command you type, PostToolUse/Skill catches one the model invokes.
#
# Writes one JSON object per line to
# $RAN_STATE_DIR/<org>/<repo>/<branch>.jsonl (default ~/.local/state/ran).
# Appending never rewrites the file, so two worktrees on one branch cannot
# clobber each other's entries.
#
# UserPromptSubmit fires on every prompt in every repo, so the cheap rejection
# comes first: one jq reads the command name, and nothing else runs (no helper
# sourcing, no git, no second parse) until that name is known to be a step.
#
# Best-effort by contract: every failure path exits 0, and nothing is ever
# written to stdout. UserPromptSubmit stdout is injected into the session as
# context, so a stray echo here would land in the model's prompt on every turn.

set -uo pipefail

command -v jq > /dev/null 2>&1 || exit 0

# read beats $(cat): no subshell, no fork. -d '' reads to EOF and returns 1 there.
IFS= read -r -d '' INPUT
[ -n "$INPUT" ] || exit 0

# One parse for everything the rejection needs. Only the command's first token
# crosses on the TSV line; a refname cannot contain whitespace, and the prompt's
# arbitrary text never does.
IFS=$'\t' read -r event cwd raw < <(
    printf '%s' "$INPUT" | jq -r '
        [ .hook_event_name // "",
          .cwd // "",
          (if .hook_event_name == "PostToolUse"
           then (if .tool_name == "Skill" then (.tool_input.skill // "") else "" end)
           else ((.prompt // "") | select(startswith("/")) | split(" ")[0])
           end) // ""
        ] | @tsv' 2> /dev/null
)

[ -n "${raw:-}" ] || exit 0
case "$event" in
    UserPromptSubmit | PostToolUse) ;;
    *) exit 0 ;;
esac

SCRIPT_DIR="${BASH_SOURCE[0]%/*}"
# shellcheck source=../helpers/command-steps.sh
. "${SCRIPT_DIR}/../helpers/command-steps.sh" 2> /dev/null || exit 0
# shellcheck source=../helpers/repo-context.sh
. "${SCRIPT_DIR}/../helpers/repo-context.sh" 2> /dev/null || exit 0

step=$(canonical_step "$raw") || exit 0

[ -n "$cwd" ] && [ -d "$cwd" ] && cd "$cwd" 2> /dev/null || exit 0
derive_org_repo || exit 0
repo_context_is_path_safe || exit 0

branch=$(git branch --show-current 2> /dev/null)
[ -n "$branch" ] || exit 0
log_file=$(command_log_path "$REPO_ORG" "$REPO_REPO" "$branch") || exit 0
sha=$(git rev-parse --short HEAD 2> /dev/null) || exit 0

mkdir -p "${log_file%/*}" 2> /dev/null || exit 0

# Reads session and agent straight off the payload rather than paying a fork
# each to pass them in.
printf '%s' "$INPUT" | jq -c \
    --arg step "$step" \
    --arg command "$raw" \
    --arg source "$(if [ "$event" = PostToolUse ]; then echo skill; else echo typed; fi)" \
    --arg sha "$sha" \
    --arg branch "$branch" \
    '{ts: (now | todate), step: $step, command: $command, source: $source,
      sha: $sha, branch: $branch,
      session: (.session_id // ""), agent: (.agent_id // null)}' \
    >> "$log_file" 2> /dev/null

exit 0
