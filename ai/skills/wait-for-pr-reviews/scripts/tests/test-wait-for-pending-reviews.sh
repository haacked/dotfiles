#!/usr/bin/env bash
# Tests for how wait-for-pending-reviews.sh blocks between checks: on `sb wait
# --block` under Switchboard, on gh-events outside it or when sb can't reach
# sbd, and on sleep when neither works.
#
# Each case copies the script next to stub check-pending-reviews.sh and
# gh-events scripts. Stub sb, sleep, and jq are the only commands in the bin
# folder that comes first on PATH, so no case reaches a real sbd. The check
# reports a pending reviewer once and nothing after that, so the script waits
# once.
#
# Usage: test-wait-for-pending-reviews.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_SCRIPTS="${SCRIPT_DIR}/.."
JQ="$(command -v jq)"

passes=0
failures=0

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
dir="${work}/case"

stub() {
  printf '#!/bin/bash\n%s\n' "$2" > "$1"
  chmod +x "$1"
}

# run_case <sb exit code or "missing"> <gh-events exit code> [SB_SESSION_ID] [sb stdout]
# Prints the calls the stubs recorded, one per line, then the script's exit code.
run_case() {
  local sb_status="$1" events_status="$2" session="${3:-}" sb_out="${4:-}"
  rm -rf "$dir"
  mkdir -p "$dir/lib" "$dir/bin"
  cp "${SKILL_SCRIPTS}/wait-for-pending-reviews.sh" "$dir/"
  cp "${SKILL_SCRIPTS}/lib/logging.sh" "$dir/lib/"
  stub "$dir/check-pending-reviews.sh" "
if [[ -e '$dir/checked' ]]; then
  echo '{\"pending\": [], \"warnings\": []}'
else
  touch '$dir/checked'
  echo '{\"pending\": [{\"reviewer\": \"copilot\", \"signal\": \"requested_reviewer\", \"since\": null}], \"warnings\": []}'
fi"
  stub "$dir/gh-events" "echo \"gh-events \$*\" >> '$dir/calls'; exit $events_status"
  stub "$dir/bin/sleep" "echo \"sleep \$*\" >> '$dir/calls'"
  if [[ "$sb_status" != missing ]]; then
    printf '%s' "$sb_out" > "$dir/sb-out"
    stub "$dir/bin/sb" "echo \"sb \$*\" >> '$dir/calls'; cat '$dir/sb-out'; exit $sb_status"
  fi
  ln -s "$JQ" "$dir/bin/jq"
  touch "$dir/calls"
  local status=0
  SB_SESSION_ID="$session" PATH="$dir/bin:/usr/bin:/bin" \
    bash "$dir/wait-for-pending-reviews.sh" owner/repo 7 --interval 30 --recheck 5 > /dev/null 2>&1 || status=$?
  cut -d' ' -f1-3 "$dir/calls"
  echo "exit $status"
}

# expect <description> <expected calls> <actual calls>
expect() {
  if [[ "$3" == "$2" ]]; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    printf 'FAIL: %s\n  expected: %q\n  actual:   %q\n' "$1" "$2" "$3"
  fi
}

# expect_args <command> <argument>...
# Checks that the last case's call to <command> passed each argument.
expect_args() {
  local call want
  call=$(grep "^$1 " "$dir/calls" || true)
  shift
  for want in "$@"; do
    if [[ "$call" == *"$want"* ]]; then
      passes=$((passes + 1))
    else
      failures=$((failures + 1))
      echo "FAIL: call lacks ${want}: ${call}"
    fi
  done
}

sb_call='sb wait --block'
events_call='gh-events wait owner/repo#7'
sleep_call='sleep 30'
nl=$'\n'

expect "outside Switchboard, the script waits on gh-events" \
  "$events_call${nl}exit 0" "$(run_case 0 0)"
expect "outside Switchboard, a failed gh-events wait sleeps" \
  "$events_call${nl}$sleep_call${nl}exit 0" "$(run_case 0 1)"
expect "under Switchboard, a resolved sb wait skips gh-events" \
  "$sb_call${nl}exit 0" "$(run_case 0 0 s1 '{"data":{"outcome":"copilot reviewed"}}')"
expect_args sb '--kind bot-review' '--target owner/repo#7' '--timeout 5' "--since $(date -u +%Y-%m-%dT)"
expect "under Switchboard, an sb timeout skips gh-events" \
  "$sb_call${nl}exit 0" "$(run_case 2 0 s1)"
expect "when sb can't reach sbd, the script waits on gh-events" \
  "$sb_call${nl}$events_call${nl}exit 0" "$(run_case 3 0 s1)"
expect_args gh-events '--kind review_submitted,merged,closed' '--timeout 5' "--since $(date -u +%Y-%m-%dT)"
expect "when sb can't reach sbd and gh-events fails, the script sleeps" \
  "$sb_call${nl}$events_call${nl}$sleep_call${nl}exit 0" "$(run_case 3 1 s1)"
expect "when sbd refuses or clears the wait, the script sleeps instead of calling gh-events" \
  "$sb_call${nl}$sleep_call${nl}exit 0" "$(run_case 1 0 s1)"
expect "a wait that resolved because the PR merged sleeps until the next recheck" \
  "$sb_call${nl}sleep 5${nl}exit 0" "$(run_case 0 0 s1 '{"data":{"outcome":"the PR merged first"}}')"
expect "without sb on PATH, SB_SESSION_ID alone sends the script to gh-events" \
  "$events_call${nl}exit 0" "$(run_case missing 0 s1)"

echo "$passes passed, $failures failed"
[[ $failures -eq 0 ]]
