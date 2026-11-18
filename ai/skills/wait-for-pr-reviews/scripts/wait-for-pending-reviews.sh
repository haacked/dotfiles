#!/usr/bin/env bash
# wait-for-pending-reviews.sh - Block until no reviews are in flight on a PR.
#
# Polls check-pending-reviews.sh until it reports nothing pending, then prints
# the final verdict JSON to stdout. Progress goes to stderr so stdout stays one
# parseable document. Designed to run in the background while the caller
# addresses the comments that already exist.
#
# Between checks the script blocks until something may have changed. Under
# Switchboard (SB_SESSION_ID set and sb on PATH), it blocks on `sb wait --block`,
# so sbd's poller is the only one that reads the PR. Otherwise, or when sb can't
# reach sbd, it blocks on the gh-events daemon's event queue. It rechecks when a
# bot review, merge, or close arrives, and after --recheck seconds without one,
# because ReviewHog can finish by editing its status comment, which produces no
# event. With neither sbd nor the daemon, it checks every --interval seconds.
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
fallback_logged=false

wait_budget() {
  local remaining=$((TIMEOUT - (SECONDS - start_seconds)))
  local budget=$((remaining < RECHECK ? remaining : RECHECK))
  echo $((budget > 1 ? budget : 1))
}

# Blocks until the next check is due. sb and gh-events both exit 0 when the wait
# resolves and 2 when --timeout passes. sb exits 3 when it can't reach sbd, and
# the script then waits on gh-events. Any other exit, such as 1 when sbd refuses
# the wait or someone clears it, makes the script sleep.
wait_for_next_check() { # since
  local status=3 budget resolved
  # A bot-review wait with no --who resolves on any bot's review, as well as on a merge or close.
  if [[ -n "${SB_SESSION_ID:-}" ]] && command -v sb >/dev/null 2>&1; then
    budget=$(wait_budget)
    status=0
    resolved=$(sb wait --block --timeout "$budget" --kind bot-review --target "${REPO}#${PR_NUMBER}" \
      --since "$1" --note "wait-for-pr-reviews: ${REPO}#${PR_NUMBER}" 2>/dev/null) || status=$?
    # sbd resolves a wait on a PR that merged or closed before the wait at once, whatever --since says.
    # Without this sleep, the script would recheck such a PR on every sbd poll.
    if [[ "$status" -eq 0 ]] && grep -qE 'PR (merged|closed) first' <<< "$resolved"; then
      sleep "$budget"
    fi
  fi
  if [[ "$status" -eq 3 ]]; then
    status=0
    "$GH_EVENTS" wait "${REPO}#${PR_NUMBER}" --kind review_submitted,merged,closed \
      --since "$1" --timeout "$(wait_budget)" >/dev/null 2>&1 || status=$?
  fi
  if [[ "$status" -eq 0 || "$status" -eq 2 ]]; then
    return
  fi
  if [[ "$fallback_logged" == false ]]; then
    fallback_logged=true
    log_info "Could not block on sbd or the gh-events daemon; checking every ${INTERVAL}s" >&2
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
