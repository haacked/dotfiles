#!/usr/bin/env bash
# Validate every skill in ai/skills/ and ai/codex/skills/ against the agentskills.io
# specification:
# directory name must equal the frontmatter `name`, description must be 1-1024
# characters, and frontmatter may only use spec keys (name, description, license,
# compatibility, metadata, allowed-tools) plus this repo's own Claude extensions
# (argument-hint, model, color, disable-model-invocation). Also checks that each
# skill has a row in the README table.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
# Shared skills, then the ones only Codex gets. Both must meet the spec.
SKILL_ROOTS=("${AI_DIR}/skills" "${AI_DIR}/codex/skills")
EXCLUSIONS="${SCRIPT_DIR}/../codex/excluded-skills.txt"
README="$(cd "${SCRIPT_DIR}/../.." && pwd)/README.md"

passes=0
failures=0

# shellcheck source=/dev/null
. "${SCRIPT_DIR}/../helpers/excluded-skills.sh"

allowed_keys="name description license compatibility metadata allowed-tools argument-hint model color disable-model-invocation"

skill_dirs=()
for skill_root in "${SKILL_ROOTS[@]}"; do
	for skill_dir in "$skill_root"/*; do
		[[ -d "$skill_dir" ]] && skill_dirs+=("$skill_dir")
	done
done

for skill_dir in "${skill_dirs[@]}"; do
	skill_name=$(basename "$skill_dir")
	skill_file="$skill_dir/SKILL.md"
	problems=""

	# The table is hand-maintained, so a new skill drops off it silently. The link has
	# to name the skill's own root, so a moved skill fails until the row moves with it.
	readme_link=$(printf '[`%s`](%s)' "$skill_name" "${skill_dir#"${AI_DIR%/ai}"/}")
	if ! grep -Fq "$readme_link" "$README"; then
		problems+="  no row in the README skill table"$'\n'
	fi

	if [[ ! -f "$skill_file" ]]; then
		problems+="  missing SKILL.md"$'\n'
	else
		# Frontmatter must open the file and close before any body content. Check
		# structurally before extracting: a leading body, a missing opening line, or a
		# missing closing line each mean "no frontmatter block", not "frontmatter to parse".
		first_line=$(head -n 1 "$skill_file")
		delimiter_count=$(grep -c '^---$' "$skill_file" || true)
		if [[ "$first_line" != "---" ]] || (( delimiter_count < 2 )); then
			problems+="  no frontmatter block"$'\n'
		else
			frontmatter=$(awk '/^---$/{n++; if (n==2) exit; next} n==1' "$skill_file")
			fm_name=$(printf '%s\n' "$frontmatter" | sed -n 's/^name:[[:space:]]*//p' | head -1 | tr -d '[:space:]')
			fm_desc=$(printf '%s\n' "$frontmatter" | sed -n 's/^description:[[:space:]]*//p' | head -1)
			fm_keys=$(printf '%s\n' "$frontmatter" | sed -n 's/^\([A-Za-z0-9_-]*\):.*/\1/p')

			if [[ "$fm_name" != "$skill_name" ]]; then
				problems+="  name '$fm_name' does not match directory '$skill_name'"$'\n'
			fi
			desc_len=${#fm_desc}
			if (( desc_len < 1 || desc_len > 1024 )); then
				problems+="  description length $desc_len outside 1-1024"$'\n'
			fi
			# `compatibility` marks a skill as Claude-only, which must track the
			# codex/excluded-skills.txt membership that install-codex.sh reads; drift
			# in either direction is silent, so enforce both.
			if printf '%s\n' "$fm_keys" | grep -Fxq compatibility && ! is_excluded_skill "$skill_name" "$EXCLUSIONS"; then
				problems+="  declares compatibility but is not in codex/excluded-skills.txt"$'\n'
			fi
			if ! printf '%s\n' "$fm_keys" | grep -Fxq compatibility && is_excluded_skill "$skill_name" "$EXCLUSIONS"; then
				problems+="  excluded from Codex but missing compatibility frontmatter"$'\n'
			fi
			while IFS= read -r key; do
				[[ -n "$key" ]] || continue
				if ! printf '%s\n' $allowed_keys | grep -Fxq "$key"; then
					problems+="  unsupported frontmatter key '$key'"$'\n'
				fi
			done <<< "$fm_keys"

			# An unquoted value containing a colon followed by a space parses as a nested
			# mapping, so the YAML loader errors and the skill never loads. The key and
			# length checks above use sed, which reads such a file without complaint.
			while IFS= read -r line; do
				[[ "$line" =~ ^[[:space:]]*[A-Za-z0-9_-]+:[[:space:]]+(.*)$ ]] || continue
				value="${BASH_REMATCH[1]}"
				[[ "$value" == \"* || "$value" == \'* ]] && continue
				if [[ "$value" == *": "* ]]; then
					problems+="  unquoted frontmatter value contains ': ' (breaks YAML parsing): $line"$'\n'
				fi
			done <<< "$frontmatter"
		fi
	fi

	if [[ -n "$problems" ]]; then
		failures=$((failures + 1))
		printf 'FAIL %s\n%s' "$skill_name" "$problems"
	else
		passes=$((passes + 1))
	fi
done

# An empty scan would otherwise read as a clean run.
if (( passes == 0 && failures == 0 )); then
	echo "FAIL no skills found under ${SKILL_ROOTS[*]}"
	exit 1
fi

echo "Validated $((passes + failures)) skills: $passes passed, $failures failed"
(( failures == 0 ))
