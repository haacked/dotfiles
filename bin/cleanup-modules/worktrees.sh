#!/bin/bash
# Worktree cleanup module
# Finds worktree directories that no git repo tracks and worktrees whose PR merged

# shellcheck disable=SC2154
# (log_message and run_cleanup are provided by parent script)

# Branch names with slashes put worktrees at <root>/<repo>/<owner>/<branch>,
# so the scan looks one level deeper than that before giving up.
WORKTREE_SCAN_MAX_DEPTH=5

# A directory with an entry modified this recently may be a worktree that
# `git worktree add` is still creating, or one someone still edits. The module
# never reports such a directory as an orphan.
WORKTREE_ORPHAN_MIN_AGE_MINUTES=60

cleanup_worktrees() {
    local mode="${1:-conservative}"
    local roots=(
        "$HOME/dev/worktrees"
        "$HOME/.supacode/repos"
        "$HOME/.agents/skills/review-code/.worktrees"
    )
    local root kind path size reason
    local worktrees=() orphans=()

    log_message "Running worktree cleanup (mode: $mode)..."

    for root in "${roots[@]}"; do
        # lsof reports resolved paths, so the scan works on resolved paths too.
        root=$(cd "$root" 2>/dev/null && pwd -P) || continue
        while IFS=$'\t' read -r kind path; do
            if [ "$kind" = worktree ]; then
                worktrees+=("$path")
            else
                orphans+=("$path")
            fi
        done < <(scan_worktree_dir "$root" 0)
    done

    # An empty list would make every directory look idle. The module therefore
    # removes nothing when lsof reports no working directories.
    local cwds
    cwds=$(process_working_dirs)
    if [ -z "$cwds" ]; then
        log_message "Could not list process working directories, keeping all worktree directories"
        return 0
    fi

    if [ ${#orphans[@]} -eq 0 ]; then
        log_message "No orphaned worktree directories"
    fi
    for path in ${orphans[@]+"${orphans[@]}"}; do
        if process_in_dir "$path" "$cwds"; then
            log_message "  Orphaned worktree directory has a process working in it, keeping: $path"
            continue
        fi
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
        # Git cannot tell whether a checkout it no longer tracks holds edits.
        if dir_holds_checkout "$path"; then
            log_message "  Orphaned checkout that may hold uncommitted edits, check it and delete it by hand: $path ($size)"
        elif [ "$mode" = "aggressive" ]; then
            run_cleanup "Remove orphaned worktree directory $path ($size)" \
                "$(printf '%s && rm -rf %q' "$(make_writable_cmd "$path")" "$path")"
        else
            log_message "  Orphaned worktree directory: $path ($size)"
        fi
    done

    if ! command -v gh >/dev/null 2>&1 || ! command -v jq >/dev/null 2>&1; then
        log_message "gh or jq not installed, skipping merged worktree check"
        return 0
    fi

    local pr number merged_oid common_dir
    for path in ${worktrees[@]+"${worktrees[@]}"}; do
        pr=$(merged_pr_for_worktree "$path") || continue
        number="${pr%%$'\t'*}"
        merged_oid="${pr#*$'\t'}"
        if reason=$(worktree_removal_blocker "$path" "$merged_oid"); then
            log_message "  Worktree for merged PR #$number has $reason, keeping: $path"
            continue
        elif supacode_may_have_session "$path"; then
            log_message "  Worktree for merged PR #$number has an open Supacode session, keeping: $path"
            continue
        elif process_in_dir "$path" "$cwds"; then
            log_message "  Worktree for merged PR #$number has a process working in it, keeping: $path"
            continue
        fi
        size=$(du -sh "$path" 2>/dev/null | cut -f1)
        if [ "$mode" = "aggressive" ]; then
            common_dir=$(git -C "$path" rev-parse --path-format=absolute --git-common-dir)
            # The second --force overrides the lock Supacode puts on worktrees it
            # manages. worktree_removal_blocker refuses every other lock.
            run_cleanup "Remove worktree for merged PR #$number: $path ($size)" \
                "$(printf '%s && git -C %q worktree remove --force --force %q' "$(make_writable_cmd "$path")" "$common_dir" "$path")"
        else
            log_message "  Worktree for merged PR #$number: $path ($size)"
        fi
    done

    if [ "$mode" != "aggressive" ]; then
        log_message "Run with --aggressive to remove the directories listed above"
    fi
    return 0
}

# Prints "worktree<TAB>path" for each live worktree or clone under $1 and
# "orphan<TAB>path" for the topmost directories that hold none. Returns 0 when
# $1 holds a live worktree or a checkout that may be live. At depth 0 it reports
# orphaned children even when the root holds no live worktree, so a root is
# never reported as an orphan. The scan stops at a checkout and at the depth
# limit, so orphan_reportable checks the whole tree of each orphan it reports.
scan_worktree_dir() {
    local dir="$1" depth="$2" child holds_worktree=1
    local orphans=()

    if [ -e "$dir/.git" ]; then
        if is_live_worktree "$dir"; then
            printf 'worktree\t%s\n' "$dir"
            return 0
        fi
        checkout_proven_stale "$dir" && return 1
        return 0
    fi
    [ "$depth" -lt "$WORKTREE_SCAN_MAX_DEPTH" ] || return 1

    for child in "$dir"/*/; do
        child="${child%/}"
        [ -d "$child" ] && [ ! -L "$child" ] || continue
        # The output has one path per line, so a name with a newline would
        # make the caller act on a different path.
        case "$child" in *$'\n'*) holds_worktree=0; continue ;; esac
        if scan_worktree_dir "$child" $((depth + 1)); then
            holds_worktree=0
        else
            orphans+=("$child")
        fi
    done

    if [ "$holds_worktree" -eq 0 ] || [ "$depth" -eq 0 ]; then
        for child in ${orphans[@]+"${orphans[@]}"}; do
            if orphan_reportable "$child"; then
                printf 'orphan\t%s\n' "$child"
            fi
        done
    fi
    return "$holds_worktree"
}

# Prints the admin dir that the .git file in checkout $1 names, as an absolute path.
git_file_admin_dir() {
    local dir="$1" line=""
    IFS= read -r line 2>/dev/null <"$dir/.git" || [ -n "$line" ] || return 1
    case "$line" in "gitdir: "*) line="${line#gitdir: }" ;; *) return 1 ;; esac
    case "$line" in /*) ;; *) line="$dir/$line" ;; esac
    printf '%s\n' "$line"
}

# Prints the .git file path that admin dir $1 records for its worktree, as an
# absolute path.
admin_dir_git_file() {
    local admin="$1" recorded=""
    IFS= read -r recorded 2>/dev/null <"$admin/gitdir" || [ -n "$recorded" ] || return 1
    case "$recorded" in /*) ;; *) recorded="$admin/$recorded" ;; esac
    printf '%s\n' "$recorded"
}

# Succeeds when $1/.git is a clone, or a .git file whose admin dir records $1 as
# its worktree or is not a worktree admin dir at all (a submodule). Paths are
# compared with -ef because APFS ignores case and git records paths as given.
is_live_worktree() {
    local dir="$1" admin
    [ -d "$dir/.git" ] && return 0
    admin=$(git_file_admin_dir "$dir") || return 1
    [ -d "$admin" ] || return 1
    [ -f "$admin/gitdir" ] || return 0
    [ "$(admin_dir_git_file "$admin")" -ef "$dir/.git" ]
}

# Succeeds only when no repo can still use checkout $1. That holds when the
# repo that the .git file names still exists but has dropped the admin dir, or
# when the admin dir belongs to another checkout that still points back at it.
# A renamed repo or a worktree moved with mv fails here, because
# `git worktree repair` can still recover it.
checkout_proven_stale() {
    local dir="$1" admin recorded other_admin
    [ -d "$dir/.git" ] && return 1
    admin=$(git_file_admin_dir "$dir") || return 1
    if [ ! -e "$admin" ]; then
        case "$admin" in */worktrees/*) ;; *) return 1 ;; esac
        [ -f "${admin%/worktrees/*}/HEAD" ]
        return
    fi
    [ -f "$admin/gitdir" ] || return 1
    recorded=$(admin_dir_git_file "$admin") || return 1
    [ "$recorded" -ef "$dir/.git" ] && return 1
    other_admin=$(git_file_admin_dir "${recorded%/.git}") || return 1
    [ "$other_admin" -ef "$admin" ]
}

# Succeeds when $1 is worth reporting as an orphan: nothing under it changed
# within the freshness window, it holds a file other than .DS_Store, and no
# live checkout sits anywhere under it.
orphan_reportable() {
    local dir="$1" found git_path
    [ -n "$(find "$dir" -mmin -"$WORKTREE_ORPHAN_MIN_AGE_MINUTES" -print -quit 2>/dev/null)" ] && return 1
    [ -n "$(find "$dir" ! -type d ! -name .DS_Store -print -quit 2>/dev/null)" ] || return 1
    # find exits non-zero when it cannot read a directory, which could hide a checkout.
    found=$(find "$dir" -name .git -prune -print) || return 1
    while IFS= read -r git_path; do
        [ -n "$git_path" ] || continue
        is_live_worktree "${git_path%/.git}" && return 1
    done <<<"$found"
    return 0
}

# Succeeds when a .git entry sits anywhere under $1, or when find cannot tell.
dir_holds_checkout() {
    local found
    found=$(find "$1" -name .git -print -quit 2>/dev/null) || return 0
    [ -n "$found" ]
}

# Prints a command that gives the owner write permission on every directory
# under $1. Go makes its module cache read-only. `rm -rf` and
# `git worktree remove` fail partway through a read-only directory.
make_writable_cmd() {
    printf 'find %q -type d ! -perm -u+w -exec chmod u+w {} +' "$1"
}

# Prints the working directory of every process this user can see, one per line.
process_working_dirs() {
    lsof -a -d cwd -Fn 2>/dev/null | sed -n 's/^n//p'
}

# Succeeds when a line of $2 is directory $1 or a path inside it.
process_in_dir() {
    local dir="$1" cwds="$2" cwd
    while IFS= read -r cwd; do
        case "$cwd" in "$dir" | "$dir"/*) return 0 ;; esac
    done <<<"$cwds"
    return 1
}

# Succeeds when Supacode has a tab open in worktree $1 or cannot answer, for
# example because the app or the CLI is missing. Fails when Supacode does not
# know the worktree or has no tab open there. A merged worktree with a session
# may still be in use, for example to watch a deploy. Supacode IDs are
# URL-encoded paths as Supacode was given them, so each one is decoded and
# compared with -ef.
supacode_may_have_session() {
    local wt="$1" ids id tabs
    command -v supacode >/dev/null 2>&1 || return 0
    ids=$(supacode worktree list --timeout 10 2>/dev/null) || return 0
    while IFS= read -r id; do
        [ -n "$id" ] || continue
        [ "$(printf '%b' "${id//%/\\x}")" -ef "$wt" ] || continue
        tabs=$(supacode tab list --worktree "$id" --timeout 10 2>/dev/null) || return 0
        [ -n "$tabs" ] && return 0
    done <<<"$ids"
    return 1
}

# Prints "<number><TAB><head oid>" for the most recent merged GitHub PR from the
# branch checked out in worktree $1. Fails for a detached HEAD, a non-GitHub
# remote, or a branch with no merged PR.
merged_pr_for_worktree() {
    local wt="$1" branch url repo
    branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD) || return 1
    url=$(git -C "$wt" remote get-url origin 2>/dev/null) || return 1
    case "$url" in *github.com[:/]*) ;; *) return 1 ;; esac
    repo=$(printf '%s\n' "$url" | sed -E 's#.*github\.com[:/]##; s#\.git$##')
    gh pr list --repo "$repo" --head "$branch" --state merged --json number,headRefOid 2>/dev/null |
        jq -er '.[0] // empty | "\(.number)\t\(.headRefOid)"'
}

# Succeeds when ignored path $1 is build output or a cache that a build or an
# install recreates.
ignored_path_regenerable() {
    case "/${1%/}/" in
    */node_modules/* | */__pycache__/* | */.venv/* | */.flox/* | */target/* | */dist/* | */build/* | \
        */.turbo/* | */.next/* | */.cache/* | */.parcel-cache/* | */.mypy_cache/* | */.pytest_cache/* | \
        */.ruff_cache/* | */.hypothesis/* | */coverage/*) return 0 ;;
    esac
    case "${1##*/}" in
    .DS_Store | .eslintcache | tsconfig.tsbuildinfo | *.pyc) return 0 ;;
    esac
    return 1
}

# Prints what removing worktree $1 would lose and succeeds, or fails when
# removal loses nothing. Removal loses nothing when HEAD is the PR's merged head
# commit $2, git status runs and shows no change, every ignored file is build
# output, no file hides an edit behind skip-worktree or assume-unchanged, no
# other checkout lives inside it, and no tool but Supacode has locked it.
worktree_removal_blocker() {
    local wt="$1" merged_oid="$2" status line flags admin
    if [ "$(git -C "$wt" rev-parse HEAD 2>/dev/null)" != "$merged_oid" ]; then
        echo "commits after the merge"
        return 0
    fi
    if ! status=$(git -C "$wt" status --porcelain --ignored=matching --untracked-files=normal --ignore-submodules=none 2>/dev/null); then
        echo "a git status that failed"
        return 0
    fi
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
        "!! "*)
            ignored_path_regenerable "${line#!! }" && continue
            echo "ignored files that are not build output, such as ${line#!! }"
            return 0
            ;;
        *)
            echo "uncommitted or untracked changes"
            return 0
            ;;
        esac
    done <<<"$status"
    if ! flags=$(git -C "$wt" ls-files -v 2>/dev/null) || grep -q '^[a-zS]' <<<"$flags"; then
        echo "files marked skip-worktree or assume-unchanged"
        return 0
    fi
    if [ -n "$(find "$wt" -mindepth 2 -name .git -print -quit 2>/dev/null)" ]; then
        echo "another checkout inside it"
        return 0
    fi
    admin=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null) || { echo "an unreadable git dir"; return 0; }
    if [ -f "$admin/locked" ] && ! grep -qF '"owner":"supacode"' "$admin/locked"; then
        echo "a lock that Supacode does not hold"
        return 0
    fi
    return 1
}
