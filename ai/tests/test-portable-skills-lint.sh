#!/usr/bin/env bash
# test-portable-skills.sh only ever reads the SKILL.md files this repo ships, and they
# all pass, so none of its four reject branches runs in CI. The matching is intricate
# enough to be worth holding: the separator-doubling sed, the trailing-dot stripping,
# and the frontmatter line offset. If the slash pattern stopped matching, CI would stay
# green while a /other-skill reference reached a portable SKILL.md, which is the upload
# refusal the portable-skills work exists to prevent.
#
# The lint takes its skills directory from PORTABLE_SKILLS_DIR, so these cases build
# fixture trees and drive the real script over them.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
LINT="${SCRIPT_DIR}/test-portable-skills.sh"

# shellcheck source=/dev/null
. "${AI_DIR}/helpers/portable-skills.sh"

passes=0
failures=0

pass() { passes=$((passes + 1)); }

fail() {
	echo "FAIL: $1"
	if [ $# -gt 1 ]; then
		printf '  %s\n' "$2"
	fi
	failures=$((failures + 1))
}

fixture=$(mktemp -d)
trap 'rm -rf "$fixture"' EXIT

# Writes a SKILL.md for every portable skill. The body is $1 with %s replaced by the
# skill's own name, so a case can reference the skill itself.
build() {
	local dir="$1" body="$2" skill
	rm -rf "$dir"
	while read -r skill; do
		mkdir -p "${dir}/${skill}"
		{
			printf -- '---\nname: %s\ndescription: fixture\n---\n\n' "$skill"
			# shellcheck disable=SC2059 # The body is a format string by design.
			printf -- "$body" "$skill"
		} >"${dir}/${skill}/SKILL.md"
	done < <(portable_skill_names)
}

# Sets $out and $status from a lint run over $1.
run_lint() {
	status=0
	out=$(PORTABLE_SKILLS_DIR="$1" "$LINT" 2>&1) || status=$?
}

clean="${fixture}/clean"
build "$clean" 'Run scripts/detect-pr.sh here. See %s for the chain.\nA bare 1/2 fraction and an http://example.com/path stay put.\n'
run_lint "$clean"
if [ "$status" -eq 0 ]; then pass; else fail 'accept SKILL.md files that name nothing outside the folder' "$out"; fi

# A skill may reference itself: the resolver has already seen that name.
case "$out" in
*'writes /'*) fail 'allow a skill to reference its own name' "$out" ;;
*) pass ;;
esac

dotfiles="${fixture}/dotfiles"
build "$dotfiles" 'Run ~/.dotfiles/bin/detect-pr.sh here.\n'
run_lint "$dotfiles"
if [ "$status" -ne 0 ]; then pass; else fail 'reject a ~/.dotfiles path'; fi
case "$out" in
*'a path no sandbox has'*) pass ;;
*) fail 'name the offending dotfiles path' "$out" ;;
esac

slash="${fixture}/slash"
build "$slash" 'Chain into /go when the branch is ready.\n'
run_lint "$slash"
if [ "$status" -ne 0 ]; then pass; else fail 'reject a slash reference'; fi
case "$out" in
*'writes /go'*) pass ;;
*) fail 'name the offending slash reference' "$out" ;;
esac

# PostHog Desktop's lookbehind allows a backtick, so a code span is still a dependency,
# and it strips trailing dots before looking a name up, so a sentence-final one counts.
span="${fixture}/span"
# shellcheck disable=SC2016 # The backticks are literal code-span characters.
build "$span" 'Invoke `/commit` first, then run /squash.\n'
run_lint "$span"
case "$out" in
*'writes /commit'*) pass ;;
*) fail 'read a reference inside a code span as a dependency' "$out" ;;
esac
case "$out" in
*'writes /squash,'*) pass ;;
*) fail 'strip the trailing dot before naming the reference' "$out" ;;
esac

wiki="${fixture}/wiki"
build "$wiki" 'See [[go]] for the chain.\n'
run_lint "$wiki"
if [ "$status" -ne 0 ]; then pass; else fail 'reject a wiki-link reference'; fi
case "$out" in
*'writes [[go]]'*) pass ;;
*) fail 'name the offending wiki link' "$out" ;;
esac

# Frontmatter runs from line 2, so the reported number is grep's count plus one.
deps="${fixture}/deps"
rm -rf "$deps"
while read -r skill; do
	mkdir -p "${deps}/${skill}"
	printf -- '---\nname: %s\ndependencies:\n  - go\n---\n\nNothing else here.\n' \
		"$skill" >"${deps}/${skill}/SKILL.md"
done < <(portable_skill_names)
run_lint "$deps"
if [ "$status" -ne 0 ]; then pass; else fail 'reject a frontmatter dependencies key'; fi
case "$out" in
*'SKILL.md:3 declares frontmatter dependencies'*) pass ;;
*) fail 'report the frontmatter line number' "$out" ;;
esac

# A file with no frontmatter has no dependencies key to find. Reading from line 2 to
# the first --- would treat prose as frontmatter, and with no --- at all it would read
# to the end of the file.
noframe="${fixture}/noframe"
rm -rf "$noframe"
while read -r skill; do
	mkdir -p "${noframe}/${skill}"
	printf -- '# %s\n\ndependencies: are discussed in this prose line\n\n---\n\nMore prose.\n' \
		"$skill" >"${noframe}/${skill}/SKILL.md"
done < <(portable_skill_names)
run_lint "$noframe"
if [ "$status" -eq 0 ]; then pass; else fail 'read prose above a horizontal rule as prose' "$out"; fi

norule="${fixture}/norule"
rm -rf "$norule"
while read -r skill; do
	mkdir -p "${norule}/${skill}"
	printf -- '# %s\n\ndependencies: discussed in prose, and no rule anywhere.\n' \
		"$skill" >"${norule}/${skill}/SKILL.md"
done < <(portable_skill_names)
run_lint "$norule"
if [ "$status" -eq 0 ]; then pass; else fail 'read a file with no frontmatter marker as prose' "$out"; fi

absent="${fixture}/absent"
build "$absent" 'Nothing here.\n'
find "$absent" -name SKILL.md -delete
run_lint "$absent"
if [ "$status" -ne 0 ]; then pass; else fail 'reject a portable skill with no SKILL.md'; fi
case "$out" in
*'has no SKILL.md'*) pass ;;
*) fail 'name the skill missing its SKILL.md' "$out" ;;
esac

echo "Passed: ${passes}, Failed: ${failures}"
[ "$failures" -eq 0 ]
