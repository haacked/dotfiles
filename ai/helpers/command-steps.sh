#!/usr/bin/env bash
# The workflow vocabulary: which commands count as a step, what order the steps
# run in, and where the log for a branch lives.
#
# Two related tables, deliberately not one-to-one. COMMAND_STEP_TABLE declares
# the pipeline the checklist renders; canonical_step maps what a user can type or
# the model can invoke onto it, and also recognizes commands that are logged
# without being positions in the sequence (go, explain-open). The set is
# editorial, not derivable: order is not a property of ai/skills/, `simplify` and
# `code-review` have no directory here at all, and the aliases are judgments.
#
# Usage: source command-steps.sh, then:
#   canonical_step /simplify   -> prints "simplify", returns 0
#   canonical_step /model      -> prints nothing, returns 1
#   command_step_table_json    -> the table as JSON, for the jq verdict
#   command_log_path <org> <repo> <branch>  -> prints the log path, returns 1 if
#                                              the branch has no safe filename

# step:evidence:optionality. `evidence` is where the row's state comes from:
# `log` for a step a command records, `commits` for one only the branch shows.
# `optional` marks a step whose absence is not worth flagging.
COMMAND_STEP_TABLE='implement:commits:required
simplify:log:required
comment-cleanup:log:optional
commit:log:required
create-pr:log:required
review-code:log:required
address-pr-reviews:log:required
ci-monitor:log:required'

# shellcheck disable=SC2034  # COMMAND_STEP_ORDER is consumed by callers.
COMMAND_STEP_ORDER=()
while IFS=: read -r _step _ _; do
    [ -n "$_step" ] && COMMAND_STEP_ORDER+=("$_step")
done <<< "$COMMAND_STEP_TABLE"
unset _step

command_step_table_json() {
    printf '%s\n' "$COMMAND_STEP_TABLE" |
        jq -R -n -c '[inputs | select(length > 0) | split(":")
                     | {step: .[0], evidence: .[1], optional: (.[2] == "optional")}]'
}

canonical_step() {
    case "${1#/}" in
        simplify) echo simplify ;;
        comment-cleanup) echo comment-cleanup ;;
        commit) echo commit ;;
        create-pr) echo create-pr ;;
        # review-fix-cycle is a review plus its own fix loop, so it satisfies the
        # same step as a direct review-code run.
        review-code | code-review | review-fix-cycle) echo review-code ;;
        address-pr-reviews) echo address-pr-reviews ;;
        ci-monitor) echo ci-monitor ;;
        explain-open) echo explain-open ;;
        go) echo go ;;
        *) return 1 ;;
    esac
}

# The writer and the reader have to agree on this byte for byte, or the report
# reads a file the hook never wrote. Callers must have validated org and repo
# with repo_context_is_path_safe first.
command_log_path() { # org repo branch
    local safe="${3//\//-}"
    safe="${safe//[!A-Za-z0-9._-]/}"
    case "$safe" in
        "" | [.-]*) return 1 ;;
    esac
    printf '%s/%s/%s/%s.jsonl' "${RAN_STATE_DIR:-$HOME/.local/state/ran}" "$1" "$2" "$safe"
}
