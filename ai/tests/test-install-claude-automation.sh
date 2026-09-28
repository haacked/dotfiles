#!/usr/bin/env bash
# Behavioral tests for ai/install-claude-automation.sh, which builds the Claude
# config directory that the scheduled jobs use for the automation account.
#
# Usage: test-install-claude-automation.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
INSTALLER="${REPO_ROOT}/ai/install-claude-automation.sh"

OPS_MCP_ADD="mcp add --scope user --transport http ops https://ops.posthog.dev/api/mcp"

# shellcheck source=bin/lib/test-helpers.sh
source "${REPO_ROOT}/bin/lib/test-helpers.sh"

TEST_ROOT=$(mktemp -d) || exit 1
SHIM_BIN="${TEST_ROOT}/bin"
CLAUDE_LOG="${TEST_ROOT}/claude-calls"
STDOUT_FILE="${TEST_ROOT}/stdout"
STDERR_FILE="${TEST_ROOT}/stderr"
INSTALLER_STATUS=0

# An inherited value would reach the installer and the stub.
unset CLAUDE_CONFIG_DIR

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

check_eq() { # description actual expected
	if [[ "$2" == "$3" ]]; then
		passes=$((passes + 1))
	else
		echo "FAIL: $1"
		echo "  expected [$3], got [$2]"
		failures=$((failures + 1))
	fi
}

# The heredoc writes the log path into the stub. The stub then logs to the right
# file even if the installer or install-claude.sh drops an environment variable.
mkdir -p "$SHIM_BIN"
cat >"${SHIM_BIN}/claude" <<SHIM
#!/usr/bin/env bash
printf '%s\t%s\n' "\${CLAUDE_CONFIG_DIR-}" "\$*" >>"${CLAUDE_LOG}"
SHIM
chmod +x "${SHIM_BIN}/claude"

fresh_home() { # name
	local home="${TEST_ROOT}/$1"
	mkdir -p "$home"
	ln -s "$REPO_ROOT" "$home/.dotfiles"
	printf '%s\n' "$home"
}

# Runs the installer under a fake HOME with the stub claude first on PATH. Any
# VAR=value prefix on the call reaches the installer's environment.
run_installer() { # home [args...]
	local home="$1"
	shift
	: >"$CLAUDE_LOG"
	HOME="$home" PATH="${SHIM_BIN}:${PATH}" "$INSTALLER" "$@" >"$STDOUT_FILE" 2>"$STDERR_FILE"
	INSTALLER_STATUS=$?
}

show_stderr_on_failure() { # description
	if [[ "$INSTALLER_STATUS" -ne 0 ]]; then
		echo "  $1 stderr:"
		sed 's/^/    /' "$STDERR_FILE"
	fi
}

symlink_target() {
	readlink "$1" 2>/dev/null || true
}

path_absent() { # path
	# A dangling symlink fails -e, so both tests are needed to call a path absent.
	[[ ! -e "$1" && ! -L "$1" ]]
}

# Prints every path under a directory with its type, each symlink's target, and
# each regular file's checksum. Two snapshots differ when anything beneath the
# directory changes.
snapshot() { # dir
	local path
	(
		cd "$1" || exit 1
		find . | LC_ALL=C sort | while IFS= read -r path; do
			if [[ -L "$path" ]]; then
				printf 'L %s -> %s\n' "$path" "$(readlink "$path")"
			elif [[ -f "$path" ]]; then
				printf 'F %s %s\n' "$path" "$(cksum <"$path")"
			else
				printf 'D %s\n' "$path"
			fi
		done
	)
}

# Succeeds when the log has at least one call that matches the pattern and every
# one of them ran with CLAUDE_CONFIG_DIR set to the given directory.
all_calls_use() { # log config-dir pattern
	awk -F'\t' -v want="$2" -v pattern="$3" '
		$2 ~ pattern { calls++; if ($1 != want) wrong++ }
		END { exit (calls > 0 && wrong == 0) ? 0 : 1 }
	' "$1"
}

# ── A first install links the shared parts of ~/.claude ─────────────────────

home=$(fresh_home links)
automation="$home/.claude-automation"
mkdir -p "$home/.claude/skills/some-skill" "$home/.claude/projects/-Users-someone-repo" "$home/.claude/plugins"
# A real ~/.claude/CLAUDE.md is itself a symlink into the dotfiles repo.
ln -s "$home/.dotfiles/ai/AGENTS.md" "$home/.claude/CLAUDE.md"
printf '%s\n' '{"model": "sonnet"}' >"$home/.claude/settings.json"
printf '%s\n' 'name: some-skill' >"$home/.claude/skills/some-skill/SKILL.md"
printf '%s\n' '{"type": "user"}' >"$home/.claude/projects/-Users-someone-repo/session.jsonl"
claude_before=$(snapshot "$home/.claude")

run_installer "$home"

check_eq "First install exits 0" "$INSTALLER_STATUS" "0"
show_stderr_on_failure "First install"
assert "First install creates the automation config dir" test -d "$automation"
for name in CLAUDE.md plugins projects settings.json skills; do
	assert "First install links $name" test -L "$automation/$name"
	check_eq "First install points $name at ~/.claude/$name" \
		"$(symlink_target "$automation/$name")" "$home/.claude/$name"
done
for name in agents commands; do
	assert "First install skips $name, which ~/.claude lacks" path_absent "$automation/$name"
done

assert "First install leaves no .claude.json in the automation dir" path_absent "$automation/.claude.json"
assert "First install leaves no .credentials.json in the automation dir" path_absent "$automation/.credentials.json"
check_eq "First install leaves ~/.claude unchanged" "$(snapshot "$home/.claude")" "$claude_before"

assert "First install registers at least one MCP server against the automation dir" \
	all_calls_use "$CLAUDE_LOG" "$automation" "^mcp add "
assert "First install reads the automation dir's MCP list" all_calls_use "$CLAUDE_LOG" "$automation" "^mcp list"
assert "First install registers the ops MCP server against the automation dir" \
	grep -Fxq -- "${automation}"$'\t'"${OPS_MCP_ADD}" "$CLAUDE_LOG"

assert "First install tells the user to run /login" grep -Fq /login "$STDOUT_FILE"

# ── A second install leaves the same links in place ────────────────────────

automation_before=$(snapshot "$automation")

run_installer "$home"

check_eq "Second install exits 0" "$INSTALLER_STATUS" "0"
show_stderr_on_failure "Second install"
check_eq "Second install leaves the automation dir unchanged" "$(snapshot "$automation")" "$automation_before"
# A plain `ln -s` onto a link to a directory would create a new link inside the
# target directory.
check_eq "Second install leaves ~/.claude unchanged" "$(snapshot "$home/.claude")" "$claude_before"

# ── A regular file at a destination is left alone ──────────────────────────

home=$(fresh_home guard)
automation="$home/.claude-automation"
mkdir -p "$home/.claude/skills" "$automation"
printf '%s\n' '{"model": "sonnet"}' >"$home/.claude/settings.json"
printf '%s\n' '{"model": "opus", "note": "hand-written"}' >"$automation/settings.json"
cp "$automation/settings.json" "${TEST_ROOT}/guard-settings.before"

run_installer "$home"

check_eq "Install with a hand-written destination exits 0" "$INSTALLER_STATUS" "0"
show_stderr_on_failure "Install with a hand-written destination"
assert "Install leaves a hand-written settings.json as a regular file" test ! -L "$automation/settings.json"
assert "Install leaves a hand-written settings.json byte-for-byte intact" \
	cmp -s "$automation/settings.json" "${TEST_ROOT}/guard-settings.before"
# The installer links skills after settings.json. This check fails if the skip
# stops the loop.
check_eq "Install still links destinations after the skipped one" \
	"$(symlink_target "$automation/skills")" "$home/.claude/skills"

# ── Missing projects and plugins directories are created in ~/.claude ──────

home=$(fresh_home fresh-claude)
automation="$home/.claude-automation"
mkdir -p "$home/.claude"

run_installer "$home"

check_eq "Install on a fresh ~/.claude exits 0" "$INSTALLER_STATUS" "0"
show_stderr_on_failure "Install on a fresh ~/.claude"
for name in plugins projects; do
	assert "Install on a fresh ~/.claude creates ~/.claude/$name" test -d "$home/.claude/$name"
	check_eq "Install on a fresh ~/.claude points $name at ~/.claude/$name" \
		"$(symlink_target "$automation/$name")" "$home/.claude/$name"
done

# ── Argument handling ──────────────────────────────────────────────────────

for flag in -h --help; do
	home=$(fresh_home "help${flag//-/_}")
	mkdir -p "$home/.claude"
	run_installer "$home" "$flag"
	check_eq "$flag exits 0" "$INSTALLER_STATUS" "0"
	assert "$flag prints usage" test -s "$STDOUT_FILE"
	assert "$flag installs nothing" path_absent "$home/.claude-automation"
done

home=$(fresh_home unknown-flag)
mkdir -p "$home/.claude"
run_installer "$home" --bogus
assert "An unknown flag exits non-zero" test "$INSTALLER_STATUS" -ne 0
assert "An unknown flag prints usage to stderr" test -s "$STDERR_FILE"
assert "An unknown flag installs nothing" path_absent "$home/.claude-automation"

print_results
