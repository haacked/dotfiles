#!/usr/bin/env bash
# Skills shared with Codex must not depend on a provider-specific install path.
# Claude-only skills listed in codex/excluded-skills.txt are exempt.
#
# TODO: the matcher below also flags prose comments that mention ~/.claude
# (e.g. sprint-planning/scripts/test_board_scripts.py:36), so it currently
# fails on main and is excluded from .github/workflows/test.yml until the
# pattern learns to skip comment lines.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
AI_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKILLS_DIR="${AI_DIR}/skills"
EXCLUSIONS="${AI_DIR}/codex/excluded-skills.txt"

passes=0
failures=0
skills_checked=0
tiers_checked=0

# shellcheck source=/dev/null
. "${AI_DIR}/helpers/excluded-skills.sh"

matches=""
for skill_dir in "$SKILLS_DIR"/*; do
	[[ -d "$skill_dir" ]] || continue
	skill_name=$(basename "$skill_dir")
	if is_excluded_skill "$skill_name" "$EXCLUSIONS"; then
		continue
	fi
	skills_checked=$((skills_checked + 1))
	# Both spellings: a script writing "${HOME}/.claude" is as provider-specific as one
	# writing ~/.claude, and only the former survives shell expansion.
	# shellcheck disable=SC2088 # A literal tilde is what we search for, not a path.
	skill_matches=$(grep -REn '~/\.claude|\$\{?HOME\}?/\.claude' "$skill_dir" 2>/dev/null || true)
	if [[ -n "$skill_matches" ]]; then
		matches+="${skill_matches}"$'\n'
	fi
done

# A glob that matches nothing would otherwise report a clean run, so treat an empty
# scan as a failure rather than a pass.
if [[ "$skills_checked" -eq 0 ]]; then
	echo "FAIL: no skills were inspected under $SKILLS_DIR"
	exit 1
fi

if [[ -n "$matches" ]]; then
	echo "FAIL: shared skills contain hardcoded ~/.claude references"
	echo "$matches"
	failures=$((failures + 1))
else
	passes=$((passes + 1))
fi

# Read the mapping out of the file the renderer uses, so a tier renamed or dropped
# there fails here instead of leaving every SKILL.md pointing at a runner Codex no
# longer has. `inherit` is the one tier with no row, by design: it needs no override.
declare -A expected_tiers=([inherit]=inherit)
while IFS='|' read -r tier claude_model _; do
	[[ -n "$tier" && "$tier" != \#* ]] || continue
	expected_tiers["$claude_model"]="$tier"
done <"${AI_DIR}/codex/model-tiers.conf"

tier_failures=0
# Codex-only skills carry the same model and tier pair, so check both roots.
for skill_file in "$SKILLS_DIR"/*/SKILL.md "${AI_DIR}"/codex/skills/*/SKILL.md; do
	[[ -f "$skill_file" ]] || continue
	model=$(sed -n 's/^model: //p' "$skill_file")
	[[ -n "$model" ]] || continue
	tiers_checked=$((tiers_checked + 1))
	tier=$(sed -n 's/^  execution-tier: //p' "$skill_file")
	if [[ "$tier" != "${expected_tiers[$model]:-unknown}" ]]; then
		echo "FAIL: $skill_file maps model $model to execution tier $tier"
		tier_failures=$((tier_failures + 1))
	fi
done

if [[ "$tier_failures" -gt 0 ]]; then
	failures=$((failures + 1))
elif [[ "$tiers_checked" -eq 0 ]]; then
	# The `model:` pattern going stale would skip every file and still report clean.
	echo "FAIL: no SKILL.md declared a model, so no tier mapping was checked"
	failures=$((failures + 1))
else
	passes=$((passes + 1))
fi

# A skill's own scripts are referenced relative to its directory, so the skill keeps
# working wherever it is installed, including a copy made outside this repo. Paths to
# another skill or to bin/ stay absolute and are the honest signal that the skill needs
# the whole repo. ci-monitor is exempt: its allowed-tools frontmatter must name the
# absolute paths Claude matches permissions against.
self_ref_failures=0
for skill_dir in "$SKILLS_DIR"/*; do
	[[ -d "$skill_dir" ]] || continue
	skill_name=$(basename "$skill_dir")
	[[ "$skill_name" == "ci-monitor" ]] && continue
	# shellcheck disable=SC2088 # A literal tilde is what we search for, not a path.
	self_refs=$(grep -RFn "~/.dotfiles/ai/skills/${skill_name}/" "$skill_dir" 2>/dev/null || true)
	if [[ -n "$self_refs" ]]; then
		echo "FAIL: $skill_name references its own directory by absolute path"
		echo "$self_refs"
		self_ref_failures=$((self_ref_failures + 1))
	fi
done

if [[ "$self_ref_failures" -gt 0 ]]; then
	failures=$((failures + 1))
else
	passes=$((passes + 1))
fi

# Codex parses a skill's `metadata` block and silently drops the whole skill when it
# is not a YAML mapping, so a typo here costs the skill with no error anywhere.
metadata_failures=0
metadata_checked=0
for skill_file in "$SKILLS_DIR"/*/SKILL.md; do
	[[ -f "$skill_file" ]] || continue
	metadata_checked=$((metadata_checked + 1))
	problem=$(awk '
		NR == 1 { if ($0 != "---") { print "no YAML frontmatter"; exit } ; infm = 1; next }
		infm && $0 == "---" { if (pending) print "metadata: has no indented entries"; exit }
		infm && pending {
			if ($0 ~ /^[[:space:]]*$/) next
			if ($0 ~ /^[[:space:]]+[^[:space:]]/) { pending = 0; next }
			print "metadata: has no indented entries"; exit
		}
		infm && /^metadata:/ {
			if ($0 !~ /^metadata:[[:space:]]*$/) { print "metadata: must be a mapping, not a scalar"; exit }
			pending = 1
		}
	' "$skill_file")
	if [[ -n "$problem" ]]; then
		echo "FAIL: $skill_file $problem"
		metadata_failures=$((metadata_failures + 1))
	fi
done

if [[ "$metadata_failures" -gt 0 ]]; then
	failures=$((failures + 1))
elif [[ "$metadata_checked" -eq 0 ]]; then
	echo "FAIL: no SKILL.md was found, so no metadata block was checked"
	failures=$((failures + 1))
else
	passes=$((passes + 1))
fi

# Every path a SKILL.md names has to resolve. The checks above police the shape of
# these references without ever opening one, so a typo in a rewritten path ships
# silently and fails at the shell when a user reaches that step.
path_failures=0
for skill_dir in "$SKILLS_DIR"/*; do
	[[ -d "$skill_dir" ]] || continue
	skill_name=$(basename "$skill_dir")
	# Excluded skills may point at Claude-only helpers that live outside this repo.
	is_excluded_skill "$skill_name" "$EXCLUSIONS" && continue
	skill_file="$skill_dir/SKILL.md"
	[[ -f "$skill_file" ]] || continue
	# Drop absolute references first: their tails look exactly like relative ones, and
	# scanning for both at once reports every cross-skill path as a missing local file.
	body=$(sed 's#~/\.dotfiles/[A-Za-z0-9._/-]*##g' "$skill_file")
	while IFS= read -r ref; do
		[[ -z "$ref" || -e "$skill_dir/$ref" ]] && continue
		echo "FAIL: $skill_file references $ref, which does not exist in the skill"
		path_failures=$((path_failures + 1))
	done < <(printf '%s\n' "$body" | grep -oE '(scripts|templates|references|handlers)/[A-Za-z0-9._-]+' | sort -u)
	# shellcheck disable=SC2088 # A literal tilde is what we search for, not a path.
	while IFS= read -r ref; do
		[[ -z "$ref" || -e "${AI_DIR}/${ref#\~/.dotfiles/ai/}" ]] && continue
		echo "FAIL: $skill_file references $ref, which does not exist in the repo"
		path_failures=$((path_failures + 1))
	done < <(grep -oE '~/\.dotfiles/ai/[A-Za-z0-9._/-]+' "$skill_file" | sort -u)
done

if [[ "$path_failures" -gt 0 ]]; then
	failures=$((failures + 1))
else
	passes=$((passes + 1))
fi

echo ""
echo "Inspected ${skills_checked} shared skills and ${tiers_checked} tiered SKILL.md files"
echo "Results: ${passes} passed, ${failures} failed"
[[ "${failures}" -eq 0 ]]
