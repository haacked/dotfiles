#!/usr/bin/env bash
# Behavioral tests for the Linux path of the repo-root install.sh.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd -P)"
INSTALLER="${REPO_ROOT}/install.sh"

# shellcheck source=bin/lib/test-helpers.sh
source "${REPO_ROOT}/bin/lib/test-helpers.sh"

TEST_ROOT=$(mktemp -d) || exit 1
TEST_ROOT=$(cd "$TEST_ROOT" && pwd -P)
trap 'rm -rf "$TEST_ROOT"' EXIT

# The uname stub reports Linux. The claude stub records each call, so a test
# can show that the installer never registers MCP servers. Registering one
# writes ~/.claude.json.
STUB_BIN="${TEST_ROOT}/bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/uname" <<'EOF'
#!/bin/sh
echo Linux
EOF
cat >"$STUB_BIN/claude" <<'EOF'
#!/bin/sh
echo "$*" >>"$HOME/claude-calls"
EOF
chmod +x "$STUB_BIN/uname" "$STUB_BIN/claude"

fresh_home() { # name
	local home="${TEST_ROOT}/$1"
	mkdir -p "$home"
	printf '%s\n' "$home"
}

run_install() { # home
	HOME="$1" PATH="$STUB_BIN:$PATH" "$INSTALLER" </dev/null >"$1/install.log" 2>&1
}

resolved() { # directory
	(cd "$1" 2>/dev/null && pwd -P)
}

json_true() { # filter file
	jq -e "$1" "$2" >/dev/null
}

# Lists every path under ~/.claude with its symlink target or content hash. It
# skips the settings backups that install-claude.sh writes on every run.
snapshot_claude() { # home
	(cd "$1/.claude" && find . -not -name 'settings.json.backup.*' | sort | while IFS= read -r p; do
		if [[ -L "$p" ]]; then
			echo "$p -> $(readlink "$p")"
		elif [[ -f "$p" ]]; then
			echo "$p $(shasum "$p" | cut -d' ' -f1)"
		else
			echo "$p"
		fi
	done)
}

HOME_FRESH=$(fresh_home fresh)

test_fresh_install() {
	local home="$HOME_FRESH"
	mkdir -p "$home/.claude"
	printf 'coder prompt\n' >"$home/.claude/CLAUDE.md"
	printf '{"oauthAccount": {"x": 1}}\n' >"$home/.claude.json"

	run_install "$home"
	check_eq "fresh install exits 0" "$?" 0

	check_eq "the dotfiles link points at the checkout" "$(resolved "$home/.dotfiles")" "$REPO_ROOT"
	check_eq "skills resolve into the checkout" "$(resolved "$home/.claude/skills/ci-monitor")" "$REPO_ROOT/ai/skills/ci-monitor"
	assert "agents are linked" bash -c "ls '$home/.claude/agents'/*.md >/dev/null 2>&1"
	assert "contexts are linked" test -L "$home/.claude/contexts"
	check_eq "the shared instructions load as a user rule" "$(readlink "$home/.claude/rules/dotfiles.md")" "$home/.dotfiles/ai/AGENTS.md"
	check_eq "Coder's CLAUDE.md is untouched" "$(cat "$home/.claude/CLAUDE.md")" "coder prompt"
	check_eq ".claude.json is untouched" "$(cat "$home/.claude.json")" '{"oauthAccount": {"x": 1}}'
	assert "hooks are configured" json_true '.hooks.PreToolUse | length > 0' "$home/.claude/settings.json"
	assert "permissions are configured" json_true '.permissions.allow | index("Bash(~/.dotfiles/ai/skills/*)")' "$home/.claude/settings.json"
	assert "claude is never called" test ! -e "$home/claude-calls"
	assert "no ~/.gitconfig is written" test ! -e "$home/.gitconfig"
	assert "no ~/.zshrc is written" test ! -e "$home/.zshrc"
	assert_not "the output reports no shell errors" grep -Eq 'not found|unexpected operator|Warning|Error' "$home/install.log"
}

test_second_run_changes_nothing() {
	local home="$HOME_FRESH" before
	before=$(snapshot_claude "$home")
	run_install "$home"
	check_eq "second run exits 0" "$?" 0
	check_eq "second run leaves ~/.claude unchanged" "$(snapshot_claude "$home")" "$before"
}

test_uninstall_removes_the_rule() {
	local home="$HOME_FRESH"
	HOME="$home" "$home/.dotfiles/ai/install-claude.sh" --uninstall >/dev/null 2>&1
	assert "uninstall removes the rule link" test ! -L "$home/.claude/rules/dotfiles.md"
	check_eq "uninstall leaves Coder's CLAUDE.md" "$(cat "$home/.claude/CLAUDE.md")" "coder prompt"
}

test_existing_paths() {
	local home
	home=$(fresh_home existing)
	ln -s "$TEST_ROOT/gone" "$home/.dotfiles"
	mkdir -p "$home/.claude/rules"
	printf 'mine\n' >"$home/.claude/rules/dotfiles.md"
	printf '{"includeCoAuthoredBy": false, "permissions": {"disableBypassPermissionsMode": false}, "skillOverrides": {"x": false}}\n' >"$home/.claude/settings.json"
	run_install "$home"
	check_eq "existing paths exit 0" "$?" 0
	check_eq "existing false settings stay false" "$(jq -c '[.includeCoAuthoredBy, .permissions.disableBypassPermissionsMode, .skillOverrides.x]' "$home/.claude/settings.json")" "[false,false,false]"
	check_eq "a dangling dotfiles link is repointed" "$(resolved "$home/.dotfiles")" "$REPO_ROOT"
	check_eq "a user-owned rule file is kept" "$(cat "$home/.claude/rules/dotfiles.md")" "mine"
}

test_foreign_dotfiles_dir_is_kept() {
	local home
	home=$(fresh_home foreign)
	mkdir -p "$home/.dotfiles/ai"
	touch "$home/.dotfiles/marker"
	printf '#!/bin/sh\ntouch "$HOME/foreign-installer-ran"\n' >"$home/.dotfiles/ai/install-claude.sh"
	chmod +x "$home/.dotfiles/ai/install-claude.sh"
	assert_not "a foreign dotfiles directory fails the install" run_install "$home"
	assert "a foreign dotfiles directory is kept" test -e "$home/.dotfiles/marker"
	assert "a foreign dotfiles directory stops before ~/.claude" test ! -e "$home/.claude"
	assert "a foreign checkout's installer never runs" test ! -e "$home/foreign-installer-ran"
	assert "the error names the foreign directory" grep -q 'is not this checkout' "$home/install.log"
}

test_fresh_install
test_second_run_changes_nothing
test_uninstall_removes_the_rule
test_existing_paths
test_foreign_dotfiles_dir_is_kept

print_results
