#!/usr/bin/env bash
# review-prs.sh - Review specific PRs of the current repo
#
# For each PR you name, this runs `/review-code <pr-url> --force --draft`,
# leaving a pending (unsubmitted) GitHub review with inline comments. Reviewing
# by URL needs no local checkout, so by default the review runs in the current
# directory.
#
# Pass --worktree to instead create a git worktree off the current repo at each
# PR's head commit and run the review inside it. Worktrees are left in place so
# you can open one and act on the review (apply fixes, push).
#
# Usage:
#   review-prs.sh PR [PR...] [--repo OWNER/NAME]
#
# PR is a PR number or a full PR URL. Bare numbers resolve against --repo if
# given, otherwise against the repo of the current directory. You can therefore
# run it from anywhere as long as you pass --repo.
#
# Options:
#   --repo OWNER/NAME  Target repo for bare PR numbers (default: current repo)
#   --worktree         Create a worktree per PR and review inside it
#   --remote NAME      Git remote to fetch PR heads from with --worktree
#                      (default: origin)
#   --dry-run          Show what would happen without making changes
#   -h, --help         Show this help message
#
# --worktree builds each worktree from the git repo you are standing in, so it
# requires the current directory to be a checkout of the target repo. Combining
# --worktree with a --repo that differs from the current repo is an error.
#
# With --worktree, each worktree is created at
#   ~/dev/worktrees/<repo>/review-<repo>-<pr>
# on a branch of the same name (review-<repo>-<pr>).
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
  --repo OWNER/NAME  Target repo for bare PR numbers (default: current repo)
  --worktree         Create a worktree per PR and review inside it
  --remote NAME      Git remote to fetch PR heads from with --worktree
                     (default: origin)
  --dry-run          Show what would happen without making changes
  -h, --help         Show this help message

By default the review runs in the current directory (reviewing by URL needs no
checkout). With --worktree, each worktree is created at
~/dev/worktrees/<repo>/review-<repo>-<pr> and left in place after the review;
--worktree requires the current directory to be a checkout of the target repo.

Examples:
  $(basename "$0") 123                          # PR #123 of the current repo
  $(basename "$0") 123 456 789                  # Three PRs in sequence
  $(basename "$0") 123 456 --repo posthog/posthog  # PRs of another repo
  $(basename "$0") --worktree 123               # Review inside a new worktree
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
# in. With --worktree, fetches the PR head and creates the worktree. Returns
# non-zero on failure.
prepare_run_dir() {
  local pr_number="$1" repo_name="$2"

  local name="review-${repo_name}-${pr_number}"
  local path="${WORKTREES_DIR}/${repo_name}/${name}"
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

  # Bring the PR head into the local repo so the new worktree can start at it.
  log_info "Fetching PR head from ${REMOTE}…" >&2
  if ! git fetch "$REMOTE" "pull/${pr_number}/head" >&2; then
    log_error "Failed to fetch pull/${pr_number}/head from ${REMOTE}."
    return 1
  fi
  local head
  head=$(git rev-parse FETCH_HEAD)

  mkdir -p "${WORKTREES_DIR}/${repo_name}"

  local wt
  if ! wt=$(worktree_create "$path" "$name" "$head"); then
    log_error "Failed to create worktree for PR #${pr_number}."
    return 1
  fi
  log_success "Worktree ready: ${wt}" >&2
  echo "$wt"
}

# Review one PR. Returns the run's exit code.
review_one() {
  local pr_url="$1" pr_number="$2" repo_name="$3"

  log_section "PR #${pr_number}"
  log_info "URL: ${pr_url}"

  if [[ "$DRY_RUN" == "true" ]]; then
    if [[ "$WORKTREE" == "true" ]]; then
      log_info "[DRY RUN] Would fetch ${REMOTE} pull/${pr_number}/head and create worktree review-${repo_name}-${pr_number}"
    fi
    log_info "[DRY RUN] Would run: claude -p \"/review-code ${pr_url} --force --draft\""
    return 0
  fi

  # Default to the current directory; reviewing by URL needs no checkout.
  local run_dir="."
  if [[ "$WORKTREE" == "true" ]]; then
    if ! run_dir=$(prepare_run_dir "$pr_number" "$repo_name"); then
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

  # --worktree builds the worktree from the repo of the current directory, so
  # that repo must be the one we're reviewing. Resolve it and reject a --repo
  # that points elsewhere.
  local cwd_repo=""
  if [[ "$WORKTREE" == "true" ]]; then
    cwd_repo=$(get_current_repo)
    if [[ -n "$REPO_FLAG" && "$REPO_FLAG" != "$cwd_repo" ]]; then
      log_error "--worktree builds from the current repo (${cwd_repo}); --repo ${REPO_FLAG} differs."
      log_error "Run from inside ${REPO_FLAG}, or drop --worktree."
      exit 1
    fi
  fi

  # The repo that bare PR numbers resolve against: --repo if given, else the
  # current directory's repo. Inferred from cwd only when a bare number needs
  # it, so an all-URL invocation works from anywhere without --repo.
  local default_repo="$REPO_FLAG"
  if [[ -z "$default_repo" ]]; then
    default_repo="$cwd_repo"  # set above only under --worktree
  fi
  if [[ -z "$default_repo" ]] && args_have_bare_number; then
    default_repo=$(get_current_repo)
  fi
  [[ -n "$default_repo" ]] && log_info "Default repo: ${default_repo}"

  local failed=0
  for arg in "${PR_ARGS[@]}"; do
    if ! resolve_pr "$arg" "$default_repo"; then
      ((failed++)) || true
      continue
    fi

    # A full URL can name a foreign repo even under --worktree (bare numbers
    # always resolve to cwd_repo, so they never reach here). Skip those rather
    # than abort the whole batch; the up-front --repo guard covers bare numbers.
    if [[ "$WORKTREE" == "true" && "$PR_REPO" != "$cwd_repo" ]]; then
      log_error "Skipping ${arg}: it is in ${PR_REPO}, but --worktree builds from ${cwd_repo}."
      ((failed++)) || true
      continue
    fi

    if ! review_one "$PR_URL" "$PR_NUMBER" "${PR_REPO##*/}"; then
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
