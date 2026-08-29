#!/usr/bin/env bash
# Record that a workflow step finished, for the /ran report and /go's resume.
#
# Usage: log-step-done.sh <step>
#
# A skill calls this as its last action, so the entry proves the work happened
# rather than that a command was submitted. log-command.sh cannot do it: both
# hooks it runs on fire before the command executes, so a review abandoned at
# the prompt writes what a finished one writes. Steps declared `completion` in
# COMMAND_STEP_TABLE count only the records this writes.
#
# Unlike the hook, this fails loudly. It runs from a SKILL.md step where a wrong
# name is a typo, and a silent exit 0 would turn that typo into a step that
# reads "never ran" on every branch with nothing to show why.

set -uo pipefail

die() {
    echo "log-step-done: $1" >&2
    exit 1
}

[ $# -eq 1 ] || die "usage: log-step-done.sh <step>"
step="$1"

command -v jq > /dev/null 2>&1 || die "jq is required"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../helpers/command-steps.sh
. "${SCRIPT_DIR}/../helpers/command-steps.sh" || die "could not load command-steps.sh"
# shellcheck source=../helpers/repo-context.sh
. "${SCRIPT_DIR}/../helpers/repo-context.sh" || die "could not load repo-context.sh"

command_step_declared "$step" || die "'$step' is not a step in COMMAND_STEP_TABLE"

derive_org_repo || die "not a GitHub repository"
repo_context_is_path_safe || die "org or repo is not safe as a path component"

branch=$(git branch --show-current 2> /dev/null)
[ -n "$branch" ] || die "detached HEAD: no branch to record against"
log_file=$(command_log_path "$REPO_ORG" "$REPO_REPO" "$branch") || die "branch name has no safe log filename"
sha=$(git rev-parse --short HEAD 2> /dev/null) || die "no commits on this branch"

mkdir -p "${log_file%/*}" || die "could not create ${log_file%/*}"

jq -c -n \
    --arg step "$step" \
    --arg sha "$sha" \
    --arg branch "$branch" \
    '{ts: (now | todate), step: $step, command: null, status: "done",
      source: "skill", sha: $sha, branch: $branch,
      session: "", agent: null}' \
    >> "$log_file" || die "could not append to $log_file"
