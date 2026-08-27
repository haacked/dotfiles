#!/usr/bin/env bash
# Behavioral tests for the shared Claude and Codex installers.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CLAUDE_INSTALLER="${REPO_ROOT}/ai/install-claude.sh"
CODEX_INSTALLER="${REPO_ROOT}/ai/install-codex.sh"
DISPATCHER="${REPO_ROOT}/ai/install.sh"
RENDERER="${REPO_ROOT}/ai/bin/render-codex-agents.py"

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
mkdir -p "$FAKE_HOME"
ln -s "$REPO_ROOT" "$FAKE_HOME/.dotfiles"

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
	passes=$((passes + 1))
}

fail() {
	echo "FAIL: $1"
	failures=$((failures + 1))
}

check() { # description command [args...]
	local description="$1"
	shift
	if "$@"; then
		pass
	else
		fail "$description"
	fi
}

check_eq() { # description actual expected
	if [[ "$2" == "$3" ]]; then
		pass
	else
		fail "$1"
		echo "  expected [$3], got [$2]"
	fi
}

run_installer() { # installer [args...]
	local installer="$1"
	shift
	HOME="$FAKE_HOME" "$installer" "$@" >/dev/null 2>&1
}

fresh_home() { # name
	local home="${TEST_ROOT}/$1"
	mkdir -p "$home"
	ln -s "$REPO_ROOT" "$home/.dotfiles"
	printf '%s\n' "$home"
}

run_dispatcher() { # home [args...]
	local home="$1"
	shift
	HOME="$home" "$DISPATCHER" "$@" >/dev/null 2>&1
}

symlink_target() {
	readlink "$1" 2>/dev/null || true
}

resolved_target() {
	python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

file_has() { # path fixed-string
	grep -Fq "$2" "$1"
}

file_lacks() { # path fixed-string
	# The file must exist: grep against a missing file also exits non-zero, which
	# would make every "lacks" assertion pass for a file the renderer never wrote.
	[[ -f "$1" ]] && ! grep -Fq "$2" "$1"
}

CODEX_EXCLUSIONS="${REPO_ROOT}/ai/codex/excluded-skills.txt"
CLAUDE_EXCLUSIONS="${REPO_ROOT}/ai/claude/excluded-skills.txt"

# shellcheck source=/dev/null
. "${REPO_ROOT}/ai/helpers/excluded-skills.sh"

# The Claude assertions below loop over this file, so a missing one would leave the
# exclusion branch untested while every loop reported success.
check "Claude exclusions are declared" test -f "$CLAUDE_EXCLUSIONS"

# The subject of every "installs a skill" assertion below, so it has to be a skill
# both platforms ship.
first_enabled_skill() {
	local skill name
	for skill in "${REPO_ROOT}"/ai/skills/*; do
		[[ -d "$skill" ]] || continue
		name=$(basename "$skill")
		if ! is_excluded_skill "$name" "$CODEX_EXCLUSIONS" &&
			! is_excluded_skill "$name" "$CLAUDE_EXCLUSIONS"; then
			printf '%s\n' "$name"
			return
		fi
	done
}

if run_installer "$CLAUDE_INSTALLER" --claude-md-only; then
	check "Claude instructions are a symlink" test -L "$FAKE_HOME/.claude/CLAUDE.md"
	check_eq "Claude uses the canonical global instructions" \
		"$(resolved_target "$FAKE_HOME/.claude/CLAUDE.md")" \
		"${REPO_ROOT}/ai/AGENTS.md"
else
	fail "Claude instruction installation succeeds"
fi

# Existing installations used the old canonical filename. Upgrade it in place.
rm -f "$FAKE_HOME/.claude/CLAUDE.md"
ln -s "$FAKE_HOME/.dotfiles/ai/CLAUDE.md" "$FAKE_HOME/.claude/CLAUDE.md"
if run_installer "$CLAUDE_INSTALLER" --claude-md-only; then
	check_eq "Claude migrates the legacy instruction symlink" \
		"$(resolved_target "$FAKE_HOME/.claude/CLAUDE.md")" \
		"${REPO_ROOT}/ai/AGENTS.md"
else
	fail "Claude legacy instruction migration succeeds"
fi

# The migration above passes even with ai/CLAUDE.md deleted, because a symlink to a
# missing target still satisfies -L. Machines that never re-run the installer keep
# pointing at ai/CLAUDE.md, so assert the shim itself still resolves.
check_eq "Legacy ai/CLAUDE.md resolves to the canonical instructions" \
	"$(resolved_target "${REPO_ROOT}/ai/CLAUDE.md")" \
	"${REPO_ROOT}/ai/AGENTS.md"

if run_installer "$CODEX_INSTALLER" --instructions-only; then
	check "Codex instructions are a symlink" test -L "$FAKE_HOME/.codex/AGENTS.md"
	check_eq "Codex uses the canonical global instructions" \
		"$(resolved_target "$FAKE_HOME/.codex/AGENTS.md")" \
		"${REPO_ROOT}/ai/AGENTS.md"
else
	fail "Codex instruction installation succeeds"
fi

enabled_skill=$(first_enabled_skill)
if [[ -n "$enabled_skill" ]] && run_installer "$CODEX_INSTALLER" --skills-only; then
	check "Codex installs enabled skills as symlinks" \
		test -L "$FAKE_HOME/.agents/skills/$enabled_skill"
	check_eq "Codex skill symlinks point at the canonical source" \
		"$(resolved_target "$FAKE_HOME/.agents/skills/$enabled_skill")" \
		"${REPO_ROOT}/ai/skills/$enabled_skill"
else
	fail "Codex skill installation succeeds"
fi

if [[ -f "$CODEX_EXCLUSIONS" ]]; then
	while IFS= read -r excluded; do
		is_excluded_skill "$excluded" "$CODEX_EXCLUSIONS" || continue
		if [[ ! -e "$FAKE_HOME/.agents/skills/$excluded" && ! -L "$FAKE_HOME/.agents/skills/$excluded" ]]; then
			pass
		else
			fail "Codex excludes skill $excluded"
		fi
	done <"$CODEX_EXCLUSIONS"
else
	fail "Codex exclusions are declared"
fi

# A second install must leave the same links in place and succeed.
before_instruction=$(symlink_target "$FAKE_HOME/.codex/AGENTS.md")
before_skill=$(symlink_target "$FAKE_HOME/.agents/skills/$enabled_skill")
if run_installer "$CODEX_INSTALLER" --no-mcp && run_installer "$CODEX_INSTALLER" --no-mcp; then
	check_eq "Repeated install preserves the instruction target" \
		"$(symlink_target "$FAKE_HOME/.codex/AGENTS.md")" "$before_instruction"
	check_eq "Repeated install preserves the skill target" \
		"$(symlink_target "$FAKE_HOME/.agents/skills/$enabled_skill")" "$before_skill"
else
	fail "Codex installation is idempotent"
fi

check "Codex install renders canonical custom agents" test -f "$FAKE_HOME/.codex/agents/code-reviewer.toml"

# Uninstall removes files owned by the installer but preserves neighboring user files.
mkdir -p "$FAKE_HOME/.agents/skills" "$FAKE_HOME/.codex/agents"
unmanaged_skill_target="${TEST_ROOT}/personal-skill"
mkdir -p "$unmanaged_skill_target"
ln -s "$unmanaged_skill_target" "$FAKE_HOME/.agents/skills/personal-skill"
echo 'name = "personal"' >"$FAKE_HOME/.codex/agents/personal.toml"
if run_installer "$CODEX_INSTALLER" --uninstall; then
	check "Codex uninstall removes its instruction symlink" test ! -L "$FAKE_HOME/.codex/AGENTS.md"
	check "Codex uninstall removes its managed skill symlink" test ! -L "$FAKE_HOME/.agents/skills/$enabled_skill"
	check "Codex uninstall removes its generated agent file" test ! -e "$FAKE_HOME/.codex/agents/code-reviewer.toml"
	check "Codex uninstall preserves an unmanaged skill symlink" test -L "$FAKE_HOME/.agents/skills/personal-skill"
	check "Codex uninstall preserves an unmanaged agent file" test -f "$FAKE_HOME/.codex/agents/personal.toml"
else
	fail "Codex uninstall succeeds"
fi

# Claude must likewise leave unmanaged symlinks alone.
mkdir -p "$FAKE_HOME/.claude/skills"
ln -s "$unmanaged_skill_target" "$FAKE_HOME/.claude/skills/personal-skill"
if run_installer "$CLAUDE_INSTALLER" --skills-only && run_installer "$CLAUDE_INSTALLER" --uninstall --skills-only; then
	check "Claude uninstall preserves an unmanaged skill symlink" test -L "$FAKE_HOME/.claude/skills/personal-skill"
else
	fail "Claude skill install and uninstall succeed"
fi

# Render a minimal fixture so every provider-tier mapping is checked directly.
fixture_agents="${TEST_ROOT}/agents"
rendered_agents="${TEST_ROOT}/rendered"
mkdir -p "$fixture_agents" "$rendered_agents"
for mapping in fast:haiku balanced:sonnet deep:opus inherited:inherit; do
	name=${mapping%%:*}
	tier=${mapping#*:}
	printf '%s\n' '---' "name: $name" "description: Fixture $name agent." "model: $tier" '---' '' "Instructions for $name." >"$fixture_agents/$name.md"
done

if python3 "$RENDERER" "$fixture_agents" "$rendered_agents" >/dev/null 2>&1; then
	check "Haiku maps to Luna" file_has "$rendered_agents/fast.toml" 'model = "gpt-5.6-luna"'
	check "Haiku uses low reasoning" file_has "$rendered_agents/fast.toml" 'model_reasoning_effort = "low"'
	check "Sonnet maps to Terra" file_has "$rendered_agents/balanced.toml" 'model = "gpt-5.6-terra"'
	check "Sonnet uses medium reasoning" file_has "$rendered_agents/balanced.toml" 'model_reasoning_effort = "medium"'
	check "Opus maps to Sol" file_has "$rendered_agents/deep.toml" 'model = "gpt-5.6-sol"'
	check "Opus uses high reasoning" file_has "$rendered_agents/deep.toml" 'model_reasoning_effort = "high"'
	check "Inherit omits a model override" file_lacks "$rendered_agents/inherited.toml" 'model = '
	check "Inherit omits a reasoning override" file_lacks "$rendered_agents/inherited.toml" 'model_reasoning_effort = '

	# ai/AGENTS.md routes every tiered skill to skill-runner-<tier>, so the generated
	# name has to match the filename Codex registers it under. Commit 5f3314c fixed a
	# mismatch here and shipped without a regression test.
	check "Fast runner name matches its filename" \
		file_has "$rendered_agents/skill-runner-fast.toml" 'name = "skill-runner-fast"'
	check "Balanced runner name matches its filename" \
		file_has "$rendered_agents/skill-runner-balanced.toml" 'name = "skill-runner-balanced"'
	check "Deep runner name matches its filename" \
		file_has "$rendered_agents/skill-runner-deep.toml" 'name = "skill-runner-deep"'
	check "Fast runner carries its tier's model" \
		file_has "$rendered_agents/skill-runner-fast.toml" 'model = "gpt-5.6-luna"'
	check "Deep runner carries its tier's model" \
		file_has "$rendered_agents/skill-runner-deep.toml" 'model = "gpt-5.6-sol"'
	check "Deep runner carries its tier's reasoning effort" \
		file_has "$rendered_agents/skill-runner-deep.toml" 'model_reasoning_effort = "high"'
else
	fail "Codex custom agents render"
fi

# Claude must preserve an unmanaged agent link and an unmanaged CLAUDE.md too.
# The agent glob requires a dot in the filename, so the fixture is named accordingly.
mkdir -p "$FAKE_HOME/.claude/agents"
unmanaged_agent_target="${TEST_ROOT}/personal-agent.md"
echo "Personal agent." >"$unmanaged_agent_target"
ln -s "$unmanaged_agent_target" "$FAKE_HOME/.claude/agents/personal.md"
if run_installer "$CLAUDE_INSTALLER" --agents-only && run_installer "$CLAUDE_INSTALLER" --uninstall --agents-only; then
	check "Claude uninstall preserves an unmanaged agent symlink" \
		test -L "$FAKE_HOME/.claude/agents/personal.md"
else
	fail "Claude agent install and uninstall succeed"
fi

unmanaged_instructions="${TEST_ROOT}/personal-CLAUDE.md"
echo "Personal instructions." >"$unmanaged_instructions"
rm -f "$FAKE_HOME/.claude/CLAUDE.md"
ln -s "$unmanaged_instructions" "$FAKE_HOME/.claude/CLAUDE.md"
if run_installer "$CLAUDE_INSTALLER" --claude-md-only; then
	check_eq "Claude install leaves an unmanaged CLAUDE.md pointing where it was" \
		"$(symlink_target "$FAKE_HOME/.claude/CLAUDE.md")" "$unmanaged_instructions"
else
	fail "Claude instruction install tolerates an unmanaged link"
fi
if run_installer "$CLAUDE_INSTALLER" --uninstall --claude-md-only; then
	check "Claude uninstall preserves an unmanaged CLAUDE.md" \
		test -L "$FAKE_HOME/.claude/CLAUDE.md"
else
	fail "Claude instruction uninstall tolerates an unmanaged link"
fi
rm -f "$FAKE_HOME/.claude/CLAUDE.md"

# The MCP env helpers are the one place the shared inventory forks per platform,
# and no install path above reaches them because every run passes --no-mcp.
# shellcheck source=/dev/null
if source "${REPO_ROOT}/ai/mcp-servers.sh"; then
	check_eq "Claude MCP env args use -e" \
		"$(set_server_env grafana)" \
		"-e PATH=${GRAFANA_MCP_PATH} -e GRAFANA_REGION=us "
	check_eq "Codex MCP env args use --env" \
		"$(set_codex_server_env grafana)" \
		"--env PATH=${GRAFANA_MCP_PATH} --env GRAFANA_REGION=us "
	check_eq "A server with no env values produces no args" \
		"$(set_codex_server_env ops)" ""
else
	fail "MCP server inventory sources cleanly"
fi

# A second render with one source removed must prune the stale output, and must
# leave a hand-written TOML alone. Only the first render runs above.
rm -f "$fixture_agents/deep.md"
printf '%s\n' 'name = "handwritten"' >"$rendered_agents/handwritten.toml"
if python3 "$RENDERER" "$fixture_agents" "$rendered_agents" >/dev/null 2>&1; then
	check "Re-render prunes output whose source is gone" test ! -e "$rendered_agents/deep.toml"
	check "Re-render keeps output whose source remains" test -f "$rendered_agents/fast.toml"
	check "Re-render leaves an unmanaged TOML alone" test -f "$rendered_agents/handwritten.toml"
else
	fail "Codex custom agents re-render"
fi

# Codex scans ~/.codex/agents recursively and does not skip dot-directories, so a
# staging directory in there registers every agent twice. Installs predating the
# move must also be migrated off the old layout.
staging_home=$(fresh_home staging)
mkdir -p "$staging_home/.codex/agents/.dotfiles"
printf '%s\n' '# Managed by ~/.dotfiles/ai/install-codex.sh.' 'name = "code-reviewer"' \
	>"$staging_home/.codex/agents/.dotfiles/code-reviewer.toml"
ln -s "$staging_home/.codex/agents/.dotfiles/code-reviewer.toml" \
	"$staging_home/.codex/agents/code-reviewer.toml"
if HOME="$staging_home" "$CODEX_INSTALLER" --agents-only >/dev/null 2>&1; then
	check_eq "Codex stages no agent TOML below ~/.codex/agents" \
		"$(find "$staging_home/.codex/agents" -mindepth 2 -name '*.toml' | wc -l | tr -d ' ')" "0"
	check "Codex removes a legacy staging directory" \
		test ! -d "$staging_home/.codex/agents/.dotfiles"
	check "Codex repoints a legacy agent symlink" \
		test -f "$staging_home/.codex/agents/code-reviewer.toml"
else
	fail "Codex agent install migrates the legacy staging layout"
fi

# ai/install.sh is what both READMEs tell people to run, so its routing needs
# coverage independent of the platform installers.
claude_only_home=$(fresh_home dispatch-claude)
if run_dispatcher "$claude_only_home" --claude-only --claude-md-only; then
	check "Dispatcher --claude-only installs Claude" test -L "$claude_only_home/.claude/CLAUDE.md"
	check "Dispatcher --claude-only leaves Codex alone" test ! -d "$claude_only_home/.codex"
	check "Dispatcher --claude-only leaves shared skills alone" test ! -d "$claude_only_home/.agents"
else
	fail "Dispatcher --claude-only succeeds"
fi

codex_only_home=$(fresh_home dispatch-codex)
if run_dispatcher "$codex_only_home" --codex-only --instructions-only; then
	check "Dispatcher --codex-only installs Codex" test -L "$codex_only_home/.codex/AGENTS.md"
	check "Dispatcher --codex-only leaves Claude alone" test ! -d "$codex_only_home/.claude"
else
	fail "Dispatcher --codex-only succeeds"
fi

# A Claude-only component flag must route to Claude from any position. Forwarding
# it to the Codex installer would abort the run after Claude had already finished.
trailing_flag_home=$(fresh_home dispatch-trailing)
if run_dispatcher "$trailing_flag_home" --claude-md-only &&
	run_dispatcher "$trailing_flag_home" --uninstall --claude-md-only; then
	check "Dispatcher routes a trailing Claude-only flag to Claude" \
		test ! -L "$trailing_flag_home/.claude/CLAUDE.md"
	check "Dispatcher routes a trailing Claude-only flag away from Codex" \
		test ! -d "$trailing_flag_home/.codex"
else
	fail "Dispatcher accepts a Claude-only flag in a trailing position"
fi

# With no routing flag the dispatcher runs both installers. Every case above routes
# to exactly one, so a regression in the fall-through would ship Codex uninstalled.
both_home=$(fresh_home dispatch-both)
# Seeded with a managed link for every Claude-excluded skill, which is what an install
# that predates the exclusion leaves behind. Running both installers over one home is
# also the only place the two platforms can be seen disagreeing about the same skill:
# Claude has to drop the link so its bundled workflow loads, Codex still ships ours.
mkdir -p "$both_home/.claude/skills"
while IFS= read -r excluded; do
	is_excluded_skill "$excluded" "$CLAUDE_EXCLUSIONS" || continue
	ln -s "$both_home/.dotfiles/ai/skills/$excluded/" "$both_home/.claude/skills/$excluded"
done <"$CLAUDE_EXCLUSIONS"
if run_dispatcher "$both_home" --skills-only; then
	check "Dispatcher with no routing flag installs Claude skills" \
		test -L "$both_home/.claude/skills/$enabled_skill"
	check "Dispatcher with no routing flag installs Codex skills" \
		test -L "$both_home/.agents/skills/$enabled_skill"
	while IFS= read -r excluded; do
		is_excluded_skill "$excluded" "$CLAUDE_EXCLUSIONS" || continue
		check "Claude drops its managed link for excluded skill $excluded" \
			test ! -e "$both_home/.claude/skills/$excluded"
		check "Codex still installs shared skill $excluded" \
			test -L "$both_home/.agents/skills/$excluded"
	done <"$CLAUDE_EXCLUSIONS"
else
	fail "Dispatcher runs both installers by default"
fi

# A link the user made by hand is not ours to delete, so an excluded name pointing
# outside the repo survives and the installer only warns about it.
excluded_home=$(fresh_home excluded-claude)
excluded_target="${TEST_ROOT}/personal-skill"
mkdir -p "$excluded_home/.claude/skills" "$excluded_target"
while IFS= read -r excluded; do
	is_excluded_skill "$excluded" "$CLAUDE_EXCLUSIONS" || continue
	ln -s "$excluded_target" "$excluded_home/.claude/skills/$excluded"
done <"$CLAUDE_EXCLUSIONS"
if HOME="$excluded_home" "$CLAUDE_INSTALLER" --skills-only >/dev/null 2>&1; then
	while IFS= read -r excluded; do
		is_excluded_skill "$excluded" "$CLAUDE_EXCLUSIONS" || continue
		check_eq "Claude preserves an unmanaged link at excluded skill $excluded" \
			"$(symlink_target "$excluded_home/.claude/skills/$excluded")" "$excluded_target"
	done <"$CLAUDE_EXCLUSIONS"
else
	fail "Claude tolerates an unmanaged excluded skill"
fi

# The guard that refuses to replace a real file or directory is what replaced the old
# rm -rf. Every unmanaged fixture above is a symlink, so that branch never runs there.
claude_dir_home=$(fresh_home guard-claude)
mkdir -p "$claude_dir_home/.claude/skills/$enabled_skill"
echo "hand-written" >"$claude_dir_home/.claude/skills/$enabled_skill/SKILL.md"
if HOME="$claude_dir_home" "$CLAUDE_INSTALLER" --skills-only >/dev/null 2>&1; then
	check "Claude install leaves a hand-written skill directory in place" \
		test ! -L "$claude_dir_home/.claude/skills/$enabled_skill"
	check_eq "Claude install preserves a hand-written skill's contents" \
		"$(cat "$claude_dir_home/.claude/skills/$enabled_skill/SKILL.md")" "hand-written"
else
	fail "Claude skill install tolerates a hand-written directory"
fi

codex_dir_home=$(fresh_home guard-codex)
mkdir -p "$codex_dir_home/.agents/skills/$enabled_skill"
echo "hand-written" >"$codex_dir_home/.agents/skills/$enabled_skill/SKILL.md"
if HOME="$codex_dir_home" "$CODEX_INSTALLER" --skills-only >/dev/null 2>&1; then
	check "Codex install leaves a hand-written skill directory in place" \
		test ! -L "$codex_dir_home/.agents/skills/$enabled_skill"
	check_eq "Codex install preserves a hand-written skill's contents" \
		"$(cat "$codex_dir_home/.agents/skills/$enabled_skill/SKILL.md")" "hand-written"
else
	fail "Codex skill install tolerates a hand-written directory"
fi

echo ""
echo "Results: $passes passed, $failures failed"
[[ "$failures" -eq 0 ]]
