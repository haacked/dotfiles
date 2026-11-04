#!/usr/bin/env bash
# spawn-task.sh - Start a Claude session on a task in its own worktree, shown in Supacode
# or, under Switchboard, as a child session in `sb ls`
#
# Usage:
#   spawn-task.sh --repo <path> --branch <new-branch> [--base <ref>] --brief <file> [options]
#   spawn-task.sh --repo <path> --existing <branch-or-PR> --brief <file> [options]
#
# Options:
#   --color <tint>   Supacode sidebar tint for the worktree
#   --title <title>  Tab title (default: the worktree's folder name)
#   --account <dir>  Claude config directory the session runs under, such as
#                    ~/claude-work. Claude's default config directory means
#                    its default account, for which the tab unsets
#                    CLAUDE_CONFIG_DIR. Without it, the tab carries this
#                    session's CLAUDE_CONFIG_DIR.
#   --plan           Start the session in plan mode
#   --go             Start the session with /go --plan-file .notes/brief.md
#   --auto           Start the session in auto permission mode. It combines
#                    with --go but not with --plan
#
# Creates the worktree with tree-me, copies the brief to <worktree>/.notes/brief.md,
# makes Supacode list the worktree, and opens a background tab that runs claude
# with the brief as its first prompt. Supacode pins the new worktree only when
# the worktree the caller runs in is pinned.
#
# --branch refuses a branch that already exists locally or on origin, and refuses
# when origin cannot be reached. Without --base, the branch starts at the remote
# default branch after a fetch. --existing runs `tree-me switch`, so it takes an
# existing branch, its worktree, or a PR number or URL. It refuses the worktree
# the caller runs in.
#
# Prints worktree=<path>, worktree_id=<supacode id>, and tab=<uuid> on success.
# A failure after the worktree exists names the --existing rerun that finishes it.
#
# Under Switchboard (SB_SESSION_ID is set), the script starts the task with
# `sb new` and does not touch Supacode or tree-me for a new branch, so the caller
# is the new session's parent and hears when it finishes. The mapping:
#   --repo      the folder `sb new` starts in
#   --branch    sb new --branch, with --base. sb new makes the worktree, under
#               ~/dev/worktrees/<name of the repo's main checkout folder>/<branch>
#   --existing  tree-me switch finds the worktree, then `sb new <worktree>` starts
#               in it. The brief is copied to <worktree>/.notes/brief.md
#   --account   sb new --account. Without it, sb new uses the caller's account
#   --title     sb new --name (default: the branch name after its last slash)
#   --go        the prompt is `/go --plan-file <brief>`. With --branch the worktree
#               does not exist yet, so <brief> is the --brief file's absolute path
#   --plan      the prompt starts with a request to plan and wait for approval.
#               sb new has no plan mode, so this is not enforced
#   --color     refused, because sb new has no tint
# Without --go, --branch puts the brief in the prompt and --existing tells the
# session to read .notes/brief.md. Prints session=<id>, name=<name>, and
# worktree=<path> on success.
#
# Exit codes: 0 success, 1 failure, 2 usage error.
#
# Environment:
#   SPAWN_TASK_LIST_TIMEOUT  seconds to wait for Supacode to list the worktree (default 30)

set -uo pipefail

lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/../../../../bin/lib"
# shellcheck source=/dev/null
source "$lib/git-default-branch.sh"
# shellcheck source=/dev/null
source "$lib/git-worktree.sh"
# shellcheck source=/dev/null
source "$lib/claude-config-dir.sh"

usage() {
    echo "usage: spawn-task.sh --repo <path> (--branch <name> [--base <ref>] | --existing <branch-or-PR>) --brief <file> [--color <tint>] [--title <title>] [--account <dir>] [--plan | --go] [--auto]" >&2
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

repo="" branch="" base="" existing="" brief="" color="" title="" account="" mode="" auto=false
while [ $# -gt 0 ]; do
    case "$1" in
        --repo | --branch | --base | --existing | --brief | --color | --title | --account)
            [ $# -ge 2 ] || usage
            printf -v "${1#--}" '%s' "$2"
            shift 2
            ;;
        --plan | --go)
            [ -z "$mode" ] || usage
            mode="${1#--}"
            shift
            ;;
        --auto)
            auto=true
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
if $auto && [ "$mode" = plan ]; then usage_error "--auto and --plan set different permission modes"; fi
[ -s "$brief" ] || usage_error "brief '$brief' is missing or empty"
[ "$(git -C "$repo" rev-parse --is-inside-work-tree 2>/dev/null)" = true ] ||
    usage_error "'$repo' is not inside a git work tree"
# These are the tints Supacode accepts. Checking here keeps a bad tint from
# failing after the worktree exists.
if [ -n "$color" ] && ! [[ "$color" =~ ^(red|orange|yellow|green|teal|blue|purple|none|#[0-9A-Fa-f]{6}([0-9A-Fa-f]{2})?)$ ]]; then
    usage_error "Supacode has no tint '$color'. Use red, orange, yellow, green, teal, blue, purple, none, or #RRGGBB[AA]."
fi

switchboard=false
[ -z "${SB_SESSION_ID:-}" ] || switchboard=true

if [ -n "$account" ]; then
    account="${account/#\~/$HOME}"
    account_dir=$(cd "$account" 2>/dev/null && pwd) || usage_error "--account '$account' is not a directory"
    account="$account_dir"
fi

if $switchboard; then
    [ -z "$color" ] || die "--color sets a Supacode tint, and sb new has no tint. Rerun without --color."
    $auto && die "--auto sets a claude permission mode, and sb new cannot pass one. Rerun without --auto."
    command -v sb >/dev/null 2>&1 || die "SB_SESSION_ID is set, but \`sb\` is not on PATH."
else
    supacode socket >/dev/null 2>&1 ||
        die "\`supacode socket\` failed. Supacode is not running, or a sandbox blocks its socket."
fi

# Starts the session with `sb new`, which sets the caller as its parent. The
# arguments are sb new's folder and flags. The prompt is the brief, or a pointer to it.
start_switchboard() { # prompt sb_new_arg...
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
    if $switchboard; then
        sb_name="${title:-${branch##*/}}"
        if [ "$mode" = go ]; then
            sb_prompt="/go --plan-file $(cd "$(dirname "$brief")" && pwd -P)/$(basename "$brief")"
        else
            sb_prompt=$(cat "$brief")
        fi
        start_switchboard "$sb_prompt" "$(cd "$repo" && pwd -P)" --branch "$branch" --base "$base" --name "$sb_name"
    fi
    tree_me_args=(create "$branch" "$base")
else
    tree_me_args=(switch "$existing")
fi

tree_me_output=$(cd "$repo" && tree-me "${tree_me_args[@]}") || {
    printf '%s\n' "$tree_me_output" >&2
    die "tree-me ${tree_me_args[*]} failed."
}
printf '%s\n' "$tree_me_output" | grep -v '^TREE_ME_CD:' >&2
worktree=$(printf '%s\n' "$tree_me_output" | sed -n 's/^TREE_ME_CD://p' | tail -1)
[ -d "$worktree" ] || die "tree-me did not report a worktree path."

caller_root=$(git rev-parse --show-toplevel 2>/dev/null) &&
    [ "$(cd "$caller_root" && pwd -P)" = "$(cd "$worktree" && pwd -P)" ] &&
    die "$worktree is the worktree this command runs in. Start the task on another branch."
rerun_hint="The worktree is at $worktree. Rerun with --existing ${branch:-$existing} to finish."

mkdir -p "$worktree/.notes" || die "cannot create $worktree/.notes."
if [ ! "$brief" -ef "$worktree/.notes/brief.md" ]; then
    cp "$brief" "$worktree/.notes/brief.md" || die "cannot copy the brief into $worktree/.notes."
fi

if $switchboard; then
    if [ "$mode" = go ]; then
        sb_prompt="/go --plan-file .notes/brief.md"
    else
        sb_prompt="Read .notes/brief.md and carry out the task it describes."
    fi
    start_switchboard "$sb_prompt" "$worktree" --name "${title:-${worktree##*/}}"
fi

# Supacode names a worktree by its percent-encoded path with a trailing slash. It
# may record the path with symlinks resolved, so both spellings are accepted.
encode() { jq -rn --arg p "$1/" '$p | @uri'; }

listed_id() { # path list_filter...
    local path="$1" listing id
    shift
    listing=$(supacode worktree list "$@" 2>/dev/null) || return 1
    for id in "$(encode "$path")" "$(encode "$(cd "$path" && pwd -P)")"; do
        if grep -qxF -- "$id" <<<"$listing"; then
            echo "$id"
            return 0
        fi
    done
    return 1
}

# Opening the repo does not bring back an archived worktree.
if ! worktree_id=$(listed_id "$worktree" --not-archived); then
    if archived_id=$(listed_id "$worktree" --status archived); then
        supacode worktree unarchive -w "$archived_id" --background >/dev/null ||
            die "could not unarchive the worktree in Supacode."
    else
        supacode repo open "$worktree" >/dev/null || die "\`supacode repo open $worktree\` failed."
    fi
    deadline=$((SECONDS + ${SPAWN_TASK_LIST_TIMEOUT:-30}))
    until worktree_id=$(listed_id "$worktree" --not-archived); do
        ((SECONDS < deadline)) || die "Supacode did not list the worktree."
        sleep 1
    done
fi

if [ -n "$caller_root" ] && listed_id "$caller_root" --status pinned >/dev/null; then
    supacode worktree pin -w "$worktree_id" --background >/dev/null || die "could not pin the worktree in Supacode."
fi
if [ -n "$color" ]; then
    supacode worktree appearance -w "$worktree_id" --color "$color" >/dev/null ||
        die "could not set the worktree's tint to '$color'."
fi

# The tab's shell reads the brief, so its content never passes through a second
# round of shell quoting. Without --, claude rejects a brief that starts with a
# dash, such as a Markdown list, as an unknown option.
# shellcheck disable=SC2016
case "$mode" in
    plan) claude_cmd='claude --permission-mode plan -- "$(cat .notes/brief.md)"' ;;
    go) claude_cmd='claude -- "/go --plan-file .notes/brief.md"' ;;
    *) claude_cmd='claude -- "$(cat .notes/brief.md)"' ;;
esac
if $auto; then
    claude_cmd="claude --permission-mode auto ${claude_cmd#claude }"
fi
# The default account runs with CLAUDE_CONFIG_DIR unset. Setting it to the default
# config directory makes claude read a different, stale .claude.json inside it.
# Without --account, the tab carries this session's account, because its login
# shell can pick a different one.
if [ -n "$account" ] && [ "$account" -ef "$CLAUDE_DEFAULT_CONFIG_DIR" ]; then
    claude_cmd="unset CLAUDE_CONFIG_DIR && $claude_cmd"
elif [ -n "$account" ]; then
    claude_cmd="CLAUDE_CONFIG_DIR=$(printf '%q' "$account") $claude_cmd"
elif [ -n "${CLAUDE_CONFIG_DIR:-}" ]; then
    claude_cmd="CLAUDE_CONFIG_DIR=$(printf '%q' "$CLAUDE_CONFIG_DIR") $claude_cmd"
fi
tab=$(supacode tab new -w "$worktree_id" --background --title "${title:-${worktree##*/}}" \
    -i "cd $(printf '%q' "$worktree") && $claude_cmd") || die "Supacode could not open a tab."

echo "worktree=$worktree"
echo "worktree_id=$worktree_id"
echo "tab=$tab"
