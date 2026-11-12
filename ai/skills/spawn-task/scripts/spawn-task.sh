#!/usr/bin/env bash
# spawn-task.sh - Start a Switchboard session on a task in its own worktree
#
# Usage:
#   spawn-task.sh --repo <path> --branch <new-branch> [--base <ref>] --brief <file> [options]
#   spawn-task.sh --repo <path> --existing <branch-or-PR> --brief <file> [options]
#
# Options:
#   --title <title>  The session's name (default: the branch name after its last
#                    slash, or for --existing the worktree's folder name)
#   --account <dir>  Claude config directory the session runs under, such as
#                    ~/claude-work. Without it, sb new picks the account
#   --plan           Ask the session to plan and wait for approval before it
#                    edits a file. sb new has no plan mode, so nothing enforces this
#   --go             Start the session with /go on the brief
#
# --branch has `sb new` make the branch and its worktree under
# ~/dev/worktrees/<name of the repo's main checkout folder>/<branch>, and start
# claude with the brief as its first prompt. With --go, the prompt is
# `/go --plan-file <brief>`, where <brief> is the --brief file's absolute path,
# because the worktree does not exist yet. --branch refuses a branch that
# already exists locally or on origin, and refuses when origin cannot be
# reached. Without --base, the branch starts at the remote default branch after
# a fetch.
#
# --existing runs `tree-me switch`, so it takes an existing branch, its
# worktree, or a PR number or URL. It refuses the worktree the caller runs in.
# It copies the brief to <worktree>/.notes/brief.md and runs `sb new` in the
# worktree with a prompt that points at the brief.
#
# sb new starts the session in auto mode unless Switchboard's autoMode setting
# is false. When the caller runs in a Switchboard session, sb new makes the
# caller the new session's parent, so the caller hears when it needs
# attention, opens a PR, or finishes.
#
# Prints session=<id>, name=<name>, and worktree=<path> on success. A failure
# after the worktree exists names the --existing rerun that finishes it.
#
# Exit codes: 0 success, 1 failure, 2 usage error.

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../../../bin/lib"
# shellcheck source=/dev/null
source "$lib/git-default-branch.sh"
# shellcheck source=/dev/null
source "$lib/git-worktree.sh"

usage() {
    echo "usage: spawn-task.sh --repo <path> (--branch <name> [--base <ref>] | --existing <branch-or-PR>) --brief <file> [--title <title>] [--account <dir>] [--plan | --go]" >&2
    exit 2
}

usage_error() {
    echo "spawn-task: $*" >&2
    usage
}

die() {
    echo "spawn-task: $*${rerun_hint:+ $rerun_hint}" >&2
    exit 1
}

rerun_hint=""

repo="" branch="" base="" existing="" brief="" title="" account="" mode=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo | --branch | --base | --existing | --brief | --title | --account)
            [ $# -ge 2 ] || usage
            printf -v "${1#--}" '%s' "$2"
            shift 2
            ;;
        --plan | --go)
            [ -z "$mode" ] || usage
            mode="${1#--}"
            shift
            ;;
        -h | --help)
            sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"
            exit 0
            ;;
        *) usage ;;
    esac
done

[ -n "$repo" ] && [ -n "$brief" ] || usage
if [ -n "$branch" ] && [ -n "$existing" ]; then usage; fi
if [ -z "$branch" ] && [ -z "$existing" ]; then usage; fi
if [ -n "$existing" ] && [ -n "$base" ]; then usage; fi
[ -s "$brief" ] || usage_error "brief '$brief' is missing or empty"
[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
    usage_error "'$repo' is not inside a git work tree"

if [ -n "$account" ]; then
    account="${account/#\~/$HOME}"
    account_dir=$(cd "$account" 2>/dev/null && pwd) || usage_error "--account '$account' is not a directory"
    account="$account_dir"
fi

command -v sb >/dev/null 2>&1 || die "\`sb\` is not on PATH. Install Switchboard, or start the task by hand."

# The arguments are sb new's folder and flags. The prompt is the brief, or a
# pointer to it.
start_session() { # prompt sb_new_arg...
    local prompt="$1" out
    shift
    [ "$mode" != plan ] || prompt="Plan first: write a plan and wait for approval before you edit any file.

$prompt"
    local sb_args=(new "$@" --prompt "$prompt" --json)
    [ -z "$account" ] || sb_args+=(--account "$account")
    out=$(sb "${sb_args[@]}") || {
        # sb new makes the branch and worktree before it starts claude.
        if [ -n "$branch" ] && git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
            die "sb new failed after it created branch '$branch'. Rerun with --existing $branch to finish."
        fi
        die "sb new failed."
    }
    jq -er 'select(.id and .name and .cwd) | "session=\(.id)", "name=\(.name)", "worktree=\(.cwd)"' <<<"$out" ||
        die "sb new printed no session. Its output was: $out"
    exit 0
}

if [ -n "$branch" ]; then
    if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
        held_by=$(cd "$repo" && worktree_path_for "$branch")
        die "branch '$branch' already exists${held_by:+ (worktree: $held_by)}. Pick a new name, or pass --existing to work on it."
    fi
    # A branch on origin can hold another task's PR. A new local branch with its
    # name would push to that branch and adopt that PR.
    git -C "$repo" ls-remote --quiet --exit-code --heads origin "refs/heads/$branch" >/dev/null
    case $? in
        0) die "branch '$branch' already exists on origin. Pick a new name, or pass --existing to work on it." ;;
        2) ;;
        *) die "cannot reach origin to check whether branch '$branch' is taken." ;;
    esac
    base="${base:-origin/$(cd "$repo" && get_default_branch)}"
    if [[ "$base" == origin/* ]]; then
        git -C "$repo" fetch --quiet origin "${base#origin/}" || die "cannot fetch $base."
    fi
    if [ "$mode" = go ]; then
        prompt="/go --plan-file $(cd "$(dirname "$brief")" && pwd -P)/$(basename "$brief")"
    else
        prompt=$(cat "$brief")
    fi
    start_session "$prompt" "$(cd "$repo" && pwd -P)" --branch "$branch" --base "$base" --name "${title:-${branch##*/}}"
fi

tree_me_output=$(cd "$repo" && tree-me switch "$existing") || {
    printf '%s\n' "$tree_me_output" >&2
    die "tree-me switch $existing failed."
}
printf '%s\n' "$tree_me_output" | grep -v '^TREE_ME_CD:' >&2
worktree=$(printf '%s\n' "$tree_me_output" | sed -n 's/^TREE_ME_CD://p' | tail -1)
[ -d "$worktree" ] || die "tree-me did not report a worktree path."

caller_root=$(git rev-parse --show-toplevel 2>/dev/null) &&
    [ "$(cd "$caller_root" && pwd -P)" = "$(cd "$worktree" && pwd -P)" ] &&
    die "$worktree is the worktree this command runs in. Start the task on another branch."
rerun_hint="The worktree is at $worktree. Rerun with --existing $existing to finish."

mkdir -p "$worktree/.notes" || die "cannot create $worktree/.notes."
if [ ! "$brief" -ef "$worktree/.notes/brief.md" ]; then
    cp "$brief" "$worktree/.notes/brief.md" || die "cannot copy the brief into $worktree/.notes."
fi

if [ "$mode" = go ]; then
    prompt="/go --plan-file .notes/brief.md"
else
    prompt="Read .notes/brief.md and carry out the task it describes."
fi
start_session "$prompt" "$worktree" --name "${title:-${worktree##*/}}"
