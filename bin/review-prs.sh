#!/usr/bin/env bash
# review-prs.sh - Review specific PRs, optionally each in its own worktree
#
# For each PR you name, this runs `/review-code <pr-url> --force --draft`,
# leaving a pending (unsubmitted) GitHub review with inline comments. Reviewing
# by URL needs no local checkout, so by default the review runs in the current
# directory.
#
# Pass --worktree to create a git worktree per PR off the repo you're standing
# in (the host repo) and run the review inside it. Worktrees are left in place.
# How each is built depends on whether the PR lives in the host repo:
#
#   - Host repo == reviewed repo: the worktree is checked out at the PR's head
#     commit, so you can apply fixes and push.
#   - Host repo != reviewed repo: the host can't hold another repo's PR, so the
#     worktree is a sandbox at the host's current HEAD. The review still runs by
#     URL; the worktree just gives the run an isolated branch and directory. Its
#     files are the host repo's, not the PR's.
#
# Usage:
#   review-prs.sh PR [PR...] [--repo OWNER/NAME]
#
# PR is a PR number or a full PR URL. Bare numbers resolve against --repo if
# given, otherwise against the repo of the current directory. You can therefore
# run it from anywhere as long as you pass --repo.
#
# Options:
#   --repo OWNER/NAME  Repo to review PRs from (default: current repo). Also the
#                      target for bare PR numbers.
#   --worktree         Create a worktree per PR and review inside it
#   --remote NAME      Git remote to fetch PR heads from when the host repo is
#                      the reviewed repo (default: origin)
#   --dry-run          Show what would happen without making changes
#   -h, --help         Show this help message
#
# --worktree requires the current directory to be a git repo (the host). The
# reviewed repo can differ from it, e.g. review posthog/posthog PRs from inside
# a scratch repo.
#
# With --worktree, each worktree is created at
#   ~/dev/worktrees/<host-repo>/review-<reviewed-repo>-<pr>
# on a branch of the same name (review-<reviewed-repo>-<pr>).
#
# Reviews run sequentially. A stuck review is bounded by a wall-clock timeout
# so it can't hang forever.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/logging.sh"
source "${SCRIPT_DIR}/lib/github.sh"
source "${SCRIPT_DIR}/lib/git-worktree.sh"

# Where per-repo worktrees live, matching the ~/dev/worktrees/<repo>/<branch>
# convention. Overridable for tests.
WORKTREES_DIR="${REVIEW_PRS_WORKTREES_DIR:-${HOME}/dev/worktrees}"
REMOTE="origin"
REPO_FLAG=""
WORKTREE=false
DRY_RUN=false
# Generous enough for a full multi-agent review; bounds a stuck run so it can't
# hang the terminal indefinitely.
REVIEW_TIMEOUT_SECONDS=1800
# SIGKILL this many seconds after SIGTERM if claude ignores the timeout.
REVIEW_KILL_AFTER_SECONDS=60

usage() {
  cat <<EOF
Usage: $(basename "$0") PR [PR...] [OPTIONS]

Review specific PRs by number or URL.

PR is a PR number or a full PR URL. Bare numbers resolve against --repo if
given, otherwise against the current directory's repo.

Options:
  --repo OWNER/NAME  Repo to review PRs from (default: current repo). Also the
                     target for bare PR numbers.
  --worktree         Create a worktree per PR and review inside it
  --remote NAME      Git remote to fetch PR heads from when the host repo is the
                     reviewed repo (default: origin)
  --dry-run          Show what would happen without making changes
  -h, --help         Show this help message

By default the review runs in the current directory (reviewing by URL needs no
checkout). With --worktree, each worktree is created at
~/dev/worktrees/<host-repo>/review-<reviewed-repo>-<pr> and left in place after
the review. When the reviewed repo is the host repo, the worktree is checked
out at the PR head; otherwise it's a sandbox at the host's HEAD.

Examples:
  $(basename "$0") 123                          # PR #123 of the current repo
  $(basename "$0") 123 456 789                  # Three PRs in sequence
  $(basename "$0") 123 456 --repo posthog/posthog  # PRs of another repo
  $(basename "$0") --worktree 123               # Review inside a new worktree
  $(basename "$0") --worktree --repo posthog/posthog 123 456  # Foreign PRs, worktrees off the host repo
  $(basename "$0") --dry-run 123                # Show what would happen
EOF
  exit 0
}

PR_ARGS=()
while [[ $# -gt 0 ]]; do
  case $1 in
    --repo)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        log_error "--repo requires a repo as OWNER/NAME"
        exit 1
      fi
      if [[ ! "$2" =~ ^[^/]+/[^/]+$ ]]; then
        log_error "--repo must be in OWNER/NAME form (got: $2)"
        exit 1
      fi
      REPO_FLAG="$2"
      shift 2
      ;;
    --worktree)
      WORKTREE=true
      shift
      ;;
    --remote)
      if [[ -z "${2:-}" || "${2:-}" == --* ]]; then
        log_error "--remote requires a remote name"
        exit 1
      fi
      REMOTE="$2"
      shift 2
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    -*)
      log_error "Unknown option: $1"
      usage
      ;;
    *)
      PR_ARGS+=("$1")
      shift
      ;;
  esac
done

if [[ "${#PR_ARGS[@]}" -eq 0 ]]; then
  log_error "No PRs specified."
  usage
fi

check_prerequisites() {
  local required=(claude gh timeout caffeinate)
  # git is only used to fetch heads and build worktrees.
  [[ "$WORKTREE" == "true" ]] && required+=(git)

  local missing=false
  for cmd in "${required[@]}"; do
    if ! command -v "$cmd" &>/dev/null; then
      log_error "Required command not found: ${cmd}"
      missing=true
    fi
  done
  [[ "$missing" == "true" ]] && exit 1

  if ! gh auth status &>/dev/null; then
    log_error "Not authenticated with GitHub. Run 'gh auth login' first."
    exit 1
  fi
}

# True if any positional PR argument is a bare number (needs a default repo).
args_have_bare_number() {
  local a
  for a in "${PR_ARGS[@]}"; do
    [[ "$a" =~ ^[0-9]+$ ]] && return 0
  done
  return 1
}

# Resolve a PR argument (number or URL). Sets the globals PR_NUMBER, PR_URL,
# and PR_REPO (owner/name). A bare number resolves against <default_repo>; a
# URL carries its own repo. Returns non-zero if the argument is malformed or a
# bare number is given with no default repo available.
resolve_pr() {
  local arg="$1" default_repo="$2"

  if [[ "$arg" =~ ^[0-9]+$ ]]; then
    if [[ -z "$default_repo" ]]; then
      log_error "PR ${arg} is a bare number but no repo is set."
      log_error "Pass --repo OWNER/NAME, run from inside the repo, or use a full PR URL."
      return 1
    fi
    PR_NUMBER="$arg"
    PR_REPO="$default_repo"
    PR_URL="https://github.com/${default_repo}/pull/${arg}"
    return 0
  fi

  if parse_pr_url "$arg"; then
    # parse_pr_url sets PR_NUMBER and REPO.
    PR_REPO="$REPO"
    PR_URL="$arg"
    return 0
  fi

  log_error "Invalid PR argument: ${arg} (expected a number or a PR URL)."
  return 1
}

# Prepare the worktree for a PR and print the directory the review should run
# in. The worktree is grouped under the host repo and named for the reviewed
# repo. When the reviewed repo is the host repo, it starts at the PR head (so
# you can apply fixes); otherwise it's a sandbox at the host's HEAD. Returns
# non-zero on failure.
prepare_run_dir() {
  local pr_number="$1" reviewed_repo_name="$2" same_repo="$3"

  local name="review-${reviewed_repo_name}-${pr_number}"
  local path="${WORKTREES_DIR}/${HOST_REPO_NAME}/${name}"
  log_info "Worktree: ${path}" >&2

  # Worktrees are left in place, so a re-run reuses an existing one as-is: it is
  # not advanced to a newer head if the PR gained commits. Short-circuit before
  # fetching so re-runs skip the network round trip. Remove it with
  # `git worktree remove <path>` for a fresh checkout.
  local existing
  existing=$(worktree_path_for "$name")
  if [[ -n "$existing" ]]; then
    log_success "Worktree ready (reused): ${existing}" >&2
    echo "$existing"
    return 0
  fi

  # Pick the commit the worktree starts at. Same-repo: the PR head, fetched into
  # the host so the checkout is the PR's code. Cross-repo: the host's HEAD, since
  # the host can't hold another repo's PR; the worktree is just a sandbox.
  local start
  if [[ "$same_repo" == "true" ]]; then
    log_info "Fetching PR head from ${REMOTE}…" >&2
    if ! git fetch "$REMOTE" "pull/${pr_number}/head" >&2; then
      log_error "Failed to fetch pull/${pr_number}/head from ${REMOTE}."
      return 1
    fi
    start=$(git rev-parse FETCH_HEAD)
  else
    start=$(git rev-parse HEAD)
  fi

  mkdir -p "${WORKTREES_DIR}/${HOST_REPO_NAME}"

  local wt
  if ! wt=$(worktree_create "$path" "$name" "$start"); then
    log_error "Failed to create worktree for PR #${pr_number}."
    return 1
  fi
  log_success "Worktree ready: ${wt}" >&2
  echo "$wt"
}

# Review one PR. Returns the run's exit code.
review_one() {
  local pr_url="$1" pr_number="$2" reviewed_repo_name="$3" same_repo="$4"

  log_section "PR #${pr_number}"
  log_info "URL: ${pr_url}"

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$WORKTREE" == "true" ]]; then
      local name="review-${reviewed_repo_name}-${pr_number}"
      if [[ "$same_repo" == "true" ]]; then
        log_info "[DRY RUN] Would fetch ${REMOTE} pull/${pr_number}/head and create worktree ${name} at the PR head"
      else
        log_info "[DRY RUN] Would create sandbox worktree ${name} off ${HOST_REPO_NAME} at HEAD"
      fi
    fi
    log_info "[DRY RUN] Would run: claude -p \"/review-code ${pr_url} --force --draft\""
    return 0
  fi

  # Default to the current directory; reviewing by URL needs no checkout.
  local run_dir="."
  if [[ "$WORKTREE" == "true" ]]; then
    if ! run_dir=$(prepare_run_dir "$pr_number" "$reviewed_repo_name" "$same_repo"); then
      return 1
    fi
  fi

  # Run the review in a subshell so the parent stays in the repo root for the
  # next PR. The heartbeat must start from the main shell.
  #
  # --force skips the skill's interactive pre-flight prompt, which a headless
  # `claude -p` run cannot answer. --draft posts a pending GitHub review with
  # inline comments (left unsubmitted for you to review and submit).
  local exit_code=0
  start_heartbeat 30 "Claude reviewing PR #${pr_number}"
  (
    cd "$run_dir" || exit 1
    caffeinate -i timeout --kill-after="$REVIEW_KILL_AFTER_SECONDS" \
      "$REVIEW_TIMEOUT_SECONDS" \
      claude -p "/review-code ${pr_url} --force --draft"
  ) || exit_code=$?
  stop_heartbeat

  if [[ "$exit_code" -eq 0 ]]; then
    log_success "Review complete for PR #${pr_number}"
  elif [[ "$exit_code" -eq 124 || "$exit_code" -eq 137 ]]; then
    log_error "Review for PR #${pr_number} timed out after ${REVIEW_TIMEOUT_SECONDS}s"
  else
    log_error "Review for PR #${pr_number} failed (exit code: ${exit_code})"
  fi
  if [[ "$WORKTREE" == "true" ]]; then
    log_info "Worktree left in place: ${run_dir}"
  fi
  return "$exit_code"
}

main() {
  trap 'stop_heartbeat' EXIT

  check_prerequisites

  # --worktree creates worktrees off the repo of the current directory (the
  # host). The reviewed repo can differ; the host is just where worktrees live.
  # HOST_REPO_NAME groups the worktree directories and HOST_REPO decides, per
  # PR, whether to fetch the PR head (same repo) or sandbox at HEAD (different).
  HOST_REPO=""
  HOST_REPO_NAME=""
  local cwd_repo=""
  if [[ "$WORKTREE" == "true" ]]; then
    cwd_repo=$(get_current_repo)
    HOST_REPO="$cwd_repo"
    HOST_REPO_NAME="${cwd_repo##*/}"
  fi

  # The repo PRs are reviewed from, and that bare numbers resolve against:
  # --repo if given, else the current directory's repo. Inferred from cwd only
  # when a bare number needs it, so an all-URL invocation works from anywhere
  # without --repo.
  local default_repo="$REPO_FLAG"
  if [[ -z "$default_repo" ]]; then
    default_repo="$cwd_repo"  # set above only under --worktree
  fi
  if [[ -z "$default_repo" ]] && args_have_bare_number; then
    default_repo=$(get_current_repo)
  fi
  [[ -n "$default_repo" ]] && log_info "Reviewed repo: ${default_repo}"

  local failed=0
  for arg in "${PR_ARGS[@]}"; do
    if ! resolve_pr "$arg" "$default_repo"; then
      ((failed++)) || true
      continue
    fi

    # Same repo means the host can hold the PR's code (fetch + checkout the PR
    # head); different means a sandbox worktree at the host's HEAD. Only matters
    # under --worktree.
    local same_repo=false
    [[ "$PR_REPO" == "$HOST_REPO" ]] && same_repo=true

    if ! review_one "$PR_URL" "$PR_NUMBER" "${PR_REPO##*/}" "$same_repo"; then
      ((failed++)) || true
    fi
  done

  log_section "Done"
  if [[ "$failed" -gt 0 ]]; then
    log_warn "${failed} PR(s) did not complete cleanly."
    exit 1
  fi
  log_success "All requested reviews finished."
}

main "$@"
