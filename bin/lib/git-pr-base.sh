#!/usr/bin/env bash
# git-pr-base.sh - Resolve the base branch a PR from HEAD targets (stack-aware)
#
# Source this file to get the resolution function:
#   source "${SCRIPT_DIR}/lib/git-pr-base.sh"
#   eval "$(get_pr_base)"
#
# Or run directly:
#   eval "$(path/to/git-pr-base.sh [--parent <ref>])"
#
# Prints eval-safe KEY=VALUE assignments on stdout, and nothing on failure, so
# an eval of the output is a no-op and the caller's empty-var check fires:
#   BASE      bare base branch name (for `gh pr create --base`, `git ls-remote`)
#   REF       diffable ref for the base, preferring origin/<BASE>
#   SOURCE    override | pr | graphite | config | default
#   PR        open PR number when SOURCE=pr, else empty
#   DEFAULT   repo default branch (bare name)
#   ANCESTOR  yes when REF's tip is an ancestor of HEAD, else no. Meaningful
#             for stacked bases; trunk normally advances past the branch
#             point, so default-based branches usually report no.
#   NOTES     empty when resolution was clean; otherwise '; '-joined notes on
#             everything that degraded it (GitHub unreachable, a recorded
#             parent ignored, a stacked base no longer an ancestor of HEAD).
#             History-rewriting callers should treat non-empty NOTES as a
#             prompt to confirm the range. Notes are mirrored on stderr.
#
# Resolution order: --parent override, the open PR's base branch (gh),
# `gt parent`, `git config branch.<name>.parent`, then the default branch.
# An open PR's base is what GitHub actually diffs and merges against, so it
# only has to resolve to a local ref. A gt/config candidate must also strictly
# narrow `git merge-base HEAD <ref>` beyond the default branch, which rejects
# rewritten or stale parents; rejected candidates fall through to the next
# source. An explicit --parent is honored as given but must resolve to a ref.
#
# Everything that can touch the network (gh, gt, default-branch detection) is
# bounded by ${GIT_PR_BASE_TIMEOUT:-5} seconds.

_pr_base_lib_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/git-default-branch.sh
source "$_pr_base_lib_dir/git-default-branch.sh"
# shellcheck source=bin/lib/bounded.sh
source "$_pr_base_lib_dir/bounded.sh"

_pr_base_ref_exists() {
  git rev-parse --verify --quiet "$1" >/dev/null 2>&1
}

# Echoes origin/<name> if that remote-tracking ref exists, else <name> if it
# resolves (branch, tag, SHA, or an explicit origin/... spelling), else nothing.
_pr_base_resolve_ref() {
  if _pr_base_ref_exists "refs/remotes/origin/$1"; then
    echo "origin/$1"
  elif _pr_base_ref_exists "$1"; then
    echo "$1"
  fi
}

# Records a degradation note: mirrored to stderr now, accumulated into the
# caller's `notes` for the NOTES output key.
_pr_base_note() {
  echo "git-pr-base: $1" >&2
  notes="${notes:+$notes; }$1"
}

# True when <ref> strictly narrows history beyond <default ref>: its
# merge-base with HEAD must be a strict descendant of the default's. Equal
# merge-bases mean a rewritten or stale parent; an older one means a parent
# forked from older trunk, which would widen the range past trunk itself.
# Treats an undeterminable merge-base as narrowing (nothing to compare).
_pr_base_narrows() {
  local ref="$1" default_ref="$2" mb_c="" mb_d=""
  mb_c=$(git merge-base HEAD "$ref" 2>/dev/null) || mb_c=""
  mb_d=$(git merge-base HEAD "$default_ref" 2>/dev/null) || mb_d=""
  if [ -z "$mb_c" ] || [ -z "$mb_d" ]; then
    return 0
  fi
  [ "$mb_c" != "$mb_d" ] && git merge-base --is-ancestor "$mb_d" "$mb_c" 2>/dev/null
}

# Vets a stack-metadata candidate (gt/config tiers): sets `vet_ref` to the
# diffable ref and returns 0 on acceptance; records a note and returns 1 on
# rejection. Candidates may be spelled with an origin/ prefix; comparison and
# resolution use the bare name. Runs unsubshelled so its notes reach NOTES.
# Args: $1 = candidate, $2 = current branch, $3 = default name, $4 = default ref
_pr_base_vet() {
  local candidate="${1#origin/}" branch="$2" default="$3" default_ref="$4"
  if [ "$candidate" = "$branch" ]; then
    _pr_base_note "ignoring recorded parent '$candidate' (it is the current branch)"
    return 1
  fi
  if [ "$candidate" = "$default" ]; then
    vet_ref="$default_ref"
    return 0
  fi
  vet_ref=$(_pr_base_resolve_ref "$candidate")
  if [ -z "$vet_ref" ]; then
    _pr_base_note "ignoring recorded parent '$candidate' (no such ref; try 'git fetch origin $candidate')"
    return 1
  fi
  if ! _pr_base_narrows "$vet_ref" "$default_ref"; then
    _pr_base_note "ignoring recorded parent '$candidate' (does not narrow history beyond '$default'; rewritten or stale?)"
    return 1
  fi
}

get_pr_base() {
  local override="" deadline="${GIT_PR_BASE_TIMEOUT:-5}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --parent | --parent=*)
        if [ "$1" = "--parent" ]; then
          override="${2:-}"
          shift
        else
          override="${1#--parent=}"
        fi
        if [ -z "$override" ]; then
          echo "git-pr-base: --parent requires a value (e.g. --parent main)" >&2
          return 2
        fi
        shift
        ;;
      *)
        echo "git-pr-base: unknown argument '$1'" >&2
        return 2
        ;;
    esac
  done

  local default="" default_ref="" branch="" base="" ref="" source="" pr="" notes="" vet_ref=""
  default=$(run_bounded "$deadline" get_default_branch) || default=""
  [ -z "$default" ] && default="main"
  default_ref=$(_pr_base_resolve_ref "$default")
  default_ref="${default_ref:-$default}"
  branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null) || branch=""

  # 1. Explicit override: honored as given, preferring the ref exactly as
  #    spelled (a local branch stays local); falls back to the origin/ form
  #    only when the spelling doesn't resolve. Report facts, don't
  #    second-guess the human.
  if [ -n "$override" ]; then
    if _pr_base_ref_exists "$override"; then
      ref="$override"
    else
      ref=$(_pr_base_resolve_ref "$override")
    fi
    if [ -z "$ref" ]; then
      echo "git-pr-base: --parent '$override' does not resolve to a ref" >&2
      return 1
    fi
    base="$override"
    source="override"
    if [ "$ref" != "$default_ref" ] && ! _pr_base_narrows "$ref" "$default_ref"; then
      echo "git-pr-base: note: '$override' does not narrow history beyond '$default'; proceeding as instructed" >&2
    fi
  fi

  # 2. The open PR's base: what GitHub actually diffs and merges against. It
  #    auto-retargets when a parent PR merges, and it is the only signal for
  #    hand-created stacked PRs. `gh pr list --head` queries the API by branch
  #    name, so it works in worktrees and after re-clones.
  if [ -z "$base" ] && [ -n "$branch" ] && command -v gh >/dev/null 2>&1; then
    local pr_line="" pr_rc=0 pr_base=""
    pr_line=$(run_bounded "$deadline" env GH_PROMPT_DISABLED=1 GH_NO_UPDATE_NOTIFIER=1 \
      gh pr list --head "$branch" --state open --json number,baseRefName \
      --jq '.[0] // {} | [(.baseRefName // ""), (.number // "" | tostring)] | @tsv') || pr_rc=$?
    if [ "$pr_rc" -ne 0 ]; then
      _pr_base_note "warning: could not check GitHub for an open PR (gh failed or timed out); falling back to local signals"
    else
      pr_base="${pr_line%%$'\t'*}"
      if [ -n "$pr_base" ]; then
        ref=$(_pr_base_resolve_ref "$pr_base")
        if [ -z "$ref" ] && [ "$pr_base" = "$default" ]; then
          ref="$default_ref"
        fi
        if [ -n "$ref" ]; then
          base="$pr_base"
          source="pr"
          pr="${pr_line#*$'\t'}"
        else
          _pr_base_note "open PR targets '$pr_base' but no local ref matches; run 'git fetch origin $pr_base' and retry"
        fi
      fi
    fi
  fi

  # 3. gt's recorded parent. Current gt keeps stack metadata in
  #    .git/.graphite_cache_persist, so `gt parent` on the current checkout is
  #    the only reliable query. A non-zero exit is gt saying it has no answer;
  #    a timeout is a degradation worth a note. Output that is not a valid
  #    branch name (e.g. gt's own setup prose) is discarded.
  if [ -z "$base" ] && [ -n "$branch" ] && command -v gt >/dev/null 2>&1; then
    local gt_out="" gt_rc=0 gt_parent=""
    gt_out=$(run_bounded "$deadline" gt parent) || gt_rc=$?
    if [ "$gt_rc" -eq 124 ]; then
      _pr_base_note "warning: 'gt parent' timed out; falling back to local signals"
    elif [ "$gt_rc" -eq 0 ]; then
      gt_parent=$(printf '%s' "$gt_out" | tr -d '[:space:]')
      git check-ref-format --branch "$gt_parent" >/dev/null 2>&1 || gt_parent=""
    fi
    if [ -n "$gt_parent" ]; then
      if _pr_base_vet "$gt_parent" "$branch" "$default" "$default_ref"; then
        base="$gt_parent"
        ref="$vet_ref"
        source="graphite"
      fi
    fi
  fi

  # 4. branch.<name>.parent, written by older gt versions and by hand.
  if [ -z "$base" ] && [ -n "$branch" ]; then
    local cfg_parent=""
    cfg_parent=$(git config --get "branch.$branch.parent" 2>/dev/null) || cfg_parent=""
    if [ -n "$cfg_parent" ]; then
      if _pr_base_vet "$cfg_parent" "$branch" "$default" "$default_ref"; then
        base="$cfg_parent"
        ref="$vet_ref"
        source="config"
      fi
    fi
  fi

  # 5. The repo default branch.
  if [ -z "$base" ]; then
    base="$default"
    ref="$default_ref"
    source="default"
  fi

  # BASE is always the bare branch name; candidates may arrive origin/-prefixed.
  base="${base#origin/}"

  local ancestor=no
  if git merge-base --is-ancestor "$ref" HEAD 2>/dev/null; then
    ancestor=yes
  fi
  if [ "$ancestor" = "no" ] && [ "$base" != "$default" ]; then
    _pr_base_note "note: '$ref' is not an ancestor of HEAD; the base may have been rewritten or advanced since this branch was cut (rebase needed?)"
  fi

  if [ "$source" != "default" ]; then
    local via="$source"
    [ "$source" = "pr" ] && via="open PR #$pr"
    [ "$source" = "override" ] && via="--parent"
    echo "git-pr-base: using '$ref' as the PR base (via $via)" >&2
  fi

  printf 'BASE=%q\n' "$base"
  printf 'REF=%q\n' "$ref"
  printf 'SOURCE=%q\n' "$source"
  printf 'PR=%q\n' "$pr"
  printf 'DEFAULT=%q\n' "$default"
  printf 'ANCESTOR=%q\n' "$ancestor"
  printf 'NOTES=%q\n' "$notes"
}

# Run directly if not being sourced
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  get_pr_base "$@"
fi
