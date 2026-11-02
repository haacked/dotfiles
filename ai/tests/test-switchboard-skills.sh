#!/usr/bin/env bash
# The skills that wait on GitHub hand the wait to Switchboard when SB_SESSION_ID
# is set, and keep their polling loop otherwise.
set -uo pipefail

SKILLS="$(cd "$(dirname "${BASH_SOURCE[0]}")/../skills" && pwd)"
passes=0
failures=0

# check <label> <file> <fixed string that file must contain>
check() {
  if grep -qF -- "$3" "$SKILLS/$2"; then
    passes=$((passes + 1))
  else
    failures=$((failures + 1))
    echo "FAIL: $1: $2 does not contain: $3"
  fi
}

check "sessions reads sbd" sessions/SKILL.md 'sb ls --json'

check "ci-monitor detects Switchboard" ci-monitor/SKILL.md 'SB_SESSION_ID'
check "ci-monitor waits through sb" ci-monitor/SKILL.md 'sb wait --kind ci'
check "ci-monitor may run sb" ci-monitor/SKILL.md 'Bash(sb:*)'
check "ci-monitor keeps its loop" ci-monitor/SKILL.md 'Otherwise wait 60 seconds'
check "ci-monitor skips sb when unattended" ci-monitor/SKILL.md '`UNATTENDED` is `false`'

check "wait-for-pr-reviews detects Switchboard" wait-for-pr-reviews/SKILL.md 'SB_SESSION_ID'
check "wait-for-pr-reviews waits through sb" wait-for-pr-reviews/SKILL.md 'sb wait --kind'
check "wait-for-pr-reviews keeps its script" wait-for-pr-reviews/SKILL.md 'scripts/wait-for-pending-reviews.sh'

echo "$passes passed, $failures failed"
[[ $failures -eq 0 ]]
