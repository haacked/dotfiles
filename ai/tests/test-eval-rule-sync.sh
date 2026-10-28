#!/usr/bin/env bash
# The smallest-change eval injects its own copy of /go's Smallest complete change rule. This test checks that the copy matches the rule in the go skill.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILL="${AI_DIR}/skills/go/SKILL.md"
RULE="${AI_DIR}/evals/smallest-change/rule.md"

# The copy drops the sentence that tells /go whom to give the rule to, because the eval has no agents to hand it to.
expected=$(awk '/^\*\*Smallest complete change\.\*\*/{p=1} /^#### /{p=0} p' "$SKILL" |
	sed 's/Give this rule to every agent that edits code, along with the judgment-call rule\. //')

if [[ -z "$expected" ]]; then
	echo "FAIL: no Smallest complete change block in ${SKILL}"
	exit 1
fi

if diff -u <(printf '%s\n' "$expected") "$RULE"; then
	echo "Results: 1 passed, 0 failed"
else
	echo "FAIL: ${RULE} differs from the rule in ${SKILL}"
	exit 1
fi
