#!/usr/bin/env bash
# wait-for-pending-reviews.sh - Block until no reviews are in flight on a PR.
#
# Polls check-pending-reviews.sh until it reports nothing pending, then prints
# the final verdict JSON to stdout. Progress goes to stderr so stdout stays one
# parseable document. Designed to run in the background while the caller
# addresses the comments that already exist.
#
# When the gh-events daemon runs on this machine, the script blocks on its event
# queue between checks instead of sleeping. It rechecks when a review, merge, or
# close event for the PR arrives, and after --recheck seconds without one,
# because ReviewHog can finish by editing its status comment, which produces no
# event. Without the daemon, it checks every --interval seconds.
#
# Usage: wait-for-pending-reviews.sh <repo> <pr_number> [--timeout <sec>] [--interval <sec>] [--recheck <sec>]
#
# Defaults: --interval 30, --recheck 300, --timeout 1800. Observed ReviewHog rounds ran ~14
# and ~22 minutes label-to-review, so the ceiling covers a round that started
# just before the caller did; the loop exits the moment a check reports clear,
# so an early finish costs nothing.
#
# Exit: 0 all clear (stdout: final verdict JSON)
#       1 bad usage, or the check failed 3 times in a row
#       2 timeout - stdout carries the last verdict so the caller can see who
#         is still pending

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/logging.sh
source "${SCRIPT_DIR}/lib/logging.sh"

CHECK_SCRIPT="${SCRIPT_DIR}/check-pending-reviews.sh"
GH_EVENTS="${SCRIPT_DIR}/gh-events"

REPO=""
PR_NUMBER=""
TIMEOUT=1800
INTERVAL=30
RECHECK=300

while [[ $# -gt 0 ]]; do
  case "$1" in
    --timeout)
      TIMEOUT="${2:?--timeout requires seconds}"
      shift 2
      ;;
    --interval)
      INTERVAL="${2:?--interval requires seconds}"
      shift 2
      ;;
    --recheck)
      RECHECK="${2:?--recheck requires seconds}"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 1
      ;;
    *)
      if [[ -z "$REPO" ]]; then
        REPO="$1"
      elif [[ -z "$PR_NUMBER" ]]; then
        PR_NUMBER="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$REPO" || -z "$PR_NUMBER" ]]; then
  echo "Usage: $(basename "$0") <repo> <pr_number> [--timeout <sec>] [--interval <sec>] [--recheck <sec>]" >&2
  exit 1
fi

start_seconds=$SECONDS
consecutive_failures=0
daemon_down_logged=false

# Blocks until the next check is due. gh-events exits 0 on a matching event and 2
# when --timeout passes without one. Any other exit means the daemon is not
# running, or python3 is missing, so the script sleeps instead. A down daemon
# makes gh-events exit at once, so each wait tries the daemon again.
wait_for_next_check() { # since
  local remaining=$((TIMEOUT - (SECONDS - start_seconds)))
  local budget=$((remaining < RECHECK ? remaining : RECHECK))
  local status=0
  "$GH_EVENTS" wait "${REPO}#${PR_NUMBER}" --kind review_submitted,merged,closed \
    --since "$1" --timeout "$((budget > 1 ? budget : 1))" >/dev/null 2>&1 || status=$?
  if [[ "$status" -eq 0 || "$status" -eq 2 ]]; then
    return
  fi
  if [[ "$daemon_down_logged" == false ]]; then
    daemon_down_logged=true
    log_info "gh-events daemon is not running; checking every ${INTERVAL}s" >&2
  fi
  sleep "$INTERVAL"
}

# Practically unreachable on stdout: a timeout requires at least one successful
# check reporting pending, which overwrites this.
last_verdict='{"pending": [], "warnings": ["timed out before any successful check"]}'

# Check-first: a state that cleared between the caller's initial check and this
# launch exits immediately, and the deadline gets one final re-check before the
# timeout verdict.
# elapsed is wall-clock (bash's SECONDS), so the deadline counts check time as
# well as sleeps - summing intervals would let slow gh calls stretch the ceiling.
while true; do
  elapsed=$((SECONDS - start_seconds))
  checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  if verdict=$("$CHECK_SCRIPT" "$REPO" "$PR_NUMBER"); then
    consecutive_failures=0
    last_verdict="$verdict"
    if [[ "$(echo "$verdict" | jq '.pending | length')" -eq 0 ]]; then
      echo "$verdict"
      exit 0
    fi
    reviewers=$(echo "$verdict" | jq -r '[.pending[].reviewer] | join(", ")')
    log_info "Waiting on ${reviewers}… (${elapsed}s/${TIMEOUT}s)" >&2
  else
    consecutive_failures=$((consecutive_failures + 1))
    log_warn "Pending-review check failed (${consecutive_failures}/3)" >&2
    if [[ "$consecutive_failures" -ge 3 ]]; then
      log_error "Giving up after 3 consecutive check failures"
      exit 1
    fi
  fi

  if [[ "$elapsed" -ge "$TIMEOUT" ]]; then
    log_warn "Timed out after ${TIMEOUT}s with reviews still pending" >&2
    echo "$last_verdict"
    exit 2
  fi

  # A failed check retries after --interval, because an event says nothing about whether the fetch would now succeed.
  if [[ "$consecutive_failures" -eq 0 ]]; then
    wait_for_next_check "$checked_at"
  else
    sleep "$INTERVAL"
  fi
done
