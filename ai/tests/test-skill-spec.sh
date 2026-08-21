#!/usr/bin/env bash
# Validate every skill in ai/skills/ against the agentskills.io specification:
# directory name must equal the frontmatter `name`, description must be 1-1024
# characters, and frontmatter may only use spec keys (name, description, license,
# compatibility, metadata, allowed-tools) plus this repo's own Claude extensions
# (argument-hint, model, color).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILLS_DIR="$(cd "${SCRIPT_DIR}/../skills" && pwd)"

passes=0
failures=0

allowed_keys="name description license compatibility metadata allowed-tools argument-hint model color"

for skill_dir in "$SKILLS_DIR"/*; do
	[[ -d "$skill_dir" ]] || continue
	skill_name=$(basename "$skill_dir")
	skill_file="$skill_dir/SKILL.md"
	problems=""

	if [[ ! -f "$skill_file" ]]; then
		problems+="  missing SKILL.md"$'\n'
	else
		# Frontmatter must open the file and close before any body content.
		frontmatter=$(awk '/^---$/{n++; if (n==2) exit; next} n==1' "$skill_file")
		if [[ -z "$frontmatter" ]]; then
			problems+="  no frontmatter block"$'\n'
		else
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
			while IFS= read -r key; do
				[[ -n "$key" ]] || continue
				if ! printf '%s\n' $allowed_keys | grep -Fxq "$key"; then
					problems+="  unsupported frontmatter key '$key'"$'\n'
				fi
			done <<< "$fm_keys"
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
	echo "FAIL no skills found under $SKILLS_DIR"
	exit 1
fi

echo "Validated $((passes + failures)) skills: $passes passed, $failures failed"
(( failures == 0 ))
