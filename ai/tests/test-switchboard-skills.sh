#!/usr/bin/env bash
# The skills that wait on GitHub hand the wait to Switchboard when SB_SESSION_ID
# is set. Their blocking loops block on `sb wait --block` then, and on gh-events
# outside Switchboard or when sb can't reach sbd.
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
check "ci-monitor blocks on sbd in its loop" ci-monitor/SKILL.md 'sb wait --block --timeout "$WAIT_SECONDS" --kind ci'
check "ci-monitor falls back to gh-events when sbd is unreachable" ci-monitor/SKILL.md 'Exit 3 means `sb` can'"'"'t reach `sbd`'
check "ci-monitor waits on gh-events outside Switchboard" ci-monitor/SKILL.md 'Outside Switchboard, wait on the `gh-events` daemon'
check "ci-monitor keeps its loop without the daemon" ci-monitor/SKILL.md 'so wait 60 seconds instead'
check "ci-monitor skips sb when unattended" ci-monitor/SKILL.md '`UNATTENDED` is `false`'
check "ci-monitor skips sb after a failure" ci-monitor/SKILL.md 'no check has failed'

check "wait-for-pr-reviews detects Switchboard" wait-for-pr-reviews/SKILL.md 'SB_SESSION_ID'
check "wait-for-pr-reviews waits through sb" wait-for-pr-reviews/SKILL.md 'sb wait --kind'
check "wait-for-pr-reviews sets a recheck wait" wait-for-pr-reviews/SKILL.md 'sb wait --kind date'
check "wait-for-pr-reviews clears its waits by id" wait-for-pr-reviews/SKILL.md '--clear --id'
check "wait-for-pr-reviews keeps its script" wait-for-pr-reviews/SKILL.md 'scripts/wait-for-pending-reviews.sh'
check "wait-for-pending-reviews blocks on sbd" wait-for-pr-reviews/scripts/wait-for-pending-reviews.sh 'sb wait --block'

echo "$passes passed, $failures failed"
[[ $failures -eq 0 ]]
