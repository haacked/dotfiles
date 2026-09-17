#!/usr/bin/env bash
# A portable skill is uploaded on its own to a cloud sandbox that holds no clone of
# this repo, so its SKILL.md must name nothing that only resolves on a developer's
# machine. Two references break such a run. A ~/.dotfiles/ path points at a directory
# the sandbox does not have. A slash or wiki-link reference to another skill is read
# as a dependency by PostHog Desktop, which then refuses the whole upload when that
# skill is a symlink the user did not tag. A frontmatter dependencies: key is read the
# same way. A skill may reference itself, which the resolver has already seen.
#
# Every `/name` other than the skill's own is reported, rather than only the names
# this repo ships. PostHog Desktop resolves names from ~/.claude/skills, ~/.agents/
# skills, and marketplace plugins too, so a list built from ai/skills/ would pass a
# reference to a skill that lives only on one machine. Prose that needs a literal
# slash path has to spell it some other way.
#
# The reference patterns mirror the parser in products/desktop/packages/
# workspace-server/src/services/skills/parse-skill-references.ts. Its lookbehind
# allows a backtick, so a reference inside a code span counts as a dependency. It also
# strips trailing dots before looking a name up, so a reference that ends a sentence
# counts too. grep has no lookaround here, so the leading and trailing characters are
# matched as ordinary character classes and stripped afterwards.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${PORTABLE_SKILLS_DIR:-${AI_DIR}/skills}"

# shellcheck source=/dev/null
. "${AI_DIR}/helpers/portable-skills.sh"

portable_skills=()
while IFS= read -r name; do
	[[ -n "$name" ]] && portable_skills+=("$name")
done < <(portable_skill_names)

# A table that went empty would otherwise report a clean run.
if [[ "${#portable_skills[@]}" -eq 0 ]]; then
	echo "FAIL: portable-skills.sh named no skills"
	exit 1
fi

slash_reference='(^|[[:space:]("'"'"'`[])/[A-Za-z0-9][A-Za-z0-9._-]*([^A-Za-z0-9._/-]|$)'
wiki_reference='\[\[[A-Za-z0-9][A-Za-z0-9._-]*\]\]'

passes=0
failures=0

for skill in "${portable_skills[@]}"; do
	skill_file="${SKILLS_DIR}/${skill}/SKILL.md"
	problems=0

	if [[ ! -f "$skill_file" ]]; then
		echo "FAIL: ${skill} has no SKILL.md"
		failures=$((failures + 1))
		continue
	fi

	# shellcheck disable=SC2088 # A literal tilde is what we search for, not a path.
	while IFS=: read -r line_number token; do
		echo "FAIL: ${skill} SKILL.md:${line_number} names ${token}, a path no sandbox has"
		problems=$((problems + 1))
	done < <(grep -noE '~/\.dotfiles/[A-Za-z0-9._/-]*' "$skill_file")

	# Doubling each separator gives two references one character apart their own
	# leading character, which a single grep -o pass would otherwise share.
	while IFS=: read -r line_number match; do
		name="${match#*/}"
		name="${name%[^A-Za-z0-9._-]}"
		while [[ "$name" == *. ]]; do name="${name%.}"; done
		[[ "$name" == "$skill" ]] && continue
		echo "FAIL: ${skill} SKILL.md:${line_number} writes /${name}, which PostHog Desktop reads as a dependency. Name it without the slash."
		problems=$((problems + 1))
	done < <(sed 's|\([^A-Za-z0-9._/-]\)|\1\1|g' "$skill_file" | grep -noE "$slash_reference")

	while IFS=: read -r line_number match; do
		name="${match#\[\[}"
		name="${name%\]\]}"
		[[ "$name" == "$skill" ]] && continue
		echo "FAIL: ${skill} SKILL.md:${line_number} writes [[${name}]], which PostHog Desktop reads as a dependency."
		problems=$((problems + 1))
	done < <(grep -noE "$wiki_reference" "$skill_file")

	# The range below runs to the end of a file that has no frontmatter, so a prose line
	# reading "dependencies:" would report as a declaration. Only a file opening with the
	# marker has frontmatter to read. Frontmatter runs from line 2 to the closing marker,
	# so grep's count is one short.
	if [[ "$(head -n 1 "$skill_file")" == "---" ]]; then
		while IFS=: read -r line_number _; do
			echo "FAIL: ${skill} SKILL.md:$((line_number + 1)) declares frontmatter dependencies, which upload other skills"
			problems=$((problems + 1))
		done < <(sed -n '2,/^---$/p' "$skill_file" | grep -n '^dependencies:')
	fi

	if [[ "$problems" -eq 0 ]]; then
		passes=$((passes + 1))
	else
		failures=$((failures + 1))
	fi
done

echo "Inspected ${#portable_skills[@]} portable skills: ${passes} passed, ${failures} failed"
(( failures == 0 ))
