#!/usr/bin/env bash
# Every skill that delegates prose editing to plain-writing must be able to call it.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${AI_DIR}/skills"

# The phrase each caller uses to hand its draft to plain-writing. Harness-neutral on
# purpose: Codex has no Skill tool, and these callers all ship to Codex.
INVOCATION="apply the \`plain-writing\` skill in technical mode"

passes=0
failures=0

pass() { passes=$((passes + 1)); }

fail() { # desc
	echo "FAIL: $1"
	failures=$((failures + 1))
}

if [[ -f "${SKILLS_DIR}/plain-writing/SKILL.md" ]]; then
	pass
else
	fail "plain-writing skill is missing"
fi

# Derived rather than hardcoded, so a new caller is covered the moment it lands and a
# caller that drops the invocation fails instead of vanishing from a stale list.
callers=$(grep -Fil "$INVOCATION" "${SKILLS_DIR}"/*/SKILL.md || true)

if [[ -z "$callers" ]]; then
	fail "no skill delegates to plain-writing"
fi

while IFS= read -r path; do
	[[ -n "$path" ]] || continue
	skill_name=$(basename "$(dirname "$path")")
	# An absent allowed-tools line means unrestricted, which already permits Skill. A
	# present one must list Skill or the delegation fails silently at runtime.
	if grep -Eq '^allowed-tools:' "$path" &&
		! grep -Eq '^allowed-tools:.*[ ,]Skill([ ,]|$)' "$path"; then
		fail "${skill_name} restricts allowed-tools without permitting Skill"
	else
		pass
	fi
done <<<"$callers"

echo "Inspected $(printf '%s\n' "$callers" | grep -c .) plain-writing callers"
echo "Results: ${passes} passed, ${failures} failed"
[[ "${failures}" -eq 0 ]]
