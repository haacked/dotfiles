#!/usr/bin/env bash
# Tests for ai/skills/spawn-task/scripts/spawn-task.sh.
#
# Each case builds its own bare origin and clone and runs the real bin/tree-me
# against them. Shims stand in for supacode and claude. The cases that check what
# claude receives run the tab's saved command in a real shell.
#
# Usage: test-spawn-task.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
SPAWN="${SCRIPT_DIR}/../spawn-task.sh"
TREE_ME="${REPO_ROOT}/bin/tree-me"

# The developer's own Claude Code, Supacode, and git variables would otherwise reach the script.
unset "${!SUPACODE_@}" "${!CLAUDE@}" "${!GIT_@}" WORKTREE_ROOT SPAWN_TASK_LIST_TIMEOUT BASH_ENV ENV

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
START_DIR="${TEST_ROOT}/start"
SHIM_BIN="${TEST_ROOT}/bin"
SHIM_PATH="${SHIM_BIN}:${PATH}"
TAB_UUID="6F1C2B3A-4D5E-4F60-8A7B-9C0D1E2F3A4B"
DEFAULT_BRIEF=$'Add a widget to the dashboard.\nThen test it.'
STATUS=0
CASE_COUNT=0
CASE_NAME=""
STALE_MAIN=""
RECEIVED_ARGS=()
CALL_ARGS=()

mkdir -p "$FAKE_HOME" "$START_DIR" "$SHIM_BIN"

# A test-owned global config and no system config keep the developer's hooks,
# signing keys, and URL rewrites out of the throwaway repos.
export GIT_CONFIG_GLOBAL="${TEST_ROOT}/gitconfig" GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
# Git stops its repository search at TEST_ROOT. A temp dir inside a work tree
# would otherwise turn the not-a-repo cases into repos.
GIT_CEILING_DIRECTORIES="${TEST_ROOT}:$(cd "$TEST_ROOT" && pwd -P)"
export GIT_CEILING_DIRECTORIES
cat > "$GIT_CONFIG_GLOBAL" <<'GITCONFIG'
[user]
	name = Test
	email = test@example.com
[commit]
	gpgsign = false
[init]
	defaultBranch = main
[advice]
	detachedHead = false
GITCONFIG

# The claude shim records its physical working directory and its arguments,
# NUL-separated, in SHIM_CLAUDE_DIR.
cat > "${SHIM_BIN}/claude" <<'SHIM'
#!/usr/bin/env bash
pwd -P > "${SHIM_CLAUDE_DIR}/cwd"
for arg in "$@"; do
	printf '%s\0' "$arg"
done > "${SHIM_CLAUDE_DIR}/args"
SHIM
chmod +x "${SHIM_BIN}/claude"

# The supacode shim logs each call's arguments, NUL-separated, to its own file in
# SHIM_DIR/calls. It appends each call's time to SHIM_DIR/call-times. The C locale
# keeps a period as the decimal point in EPOCHREALTIME. The shim answers from
# files in SHIM_DIR that each case sets:
#   fail        subcommands, such as "socket" or "tab new", that exit 1
#   listed      the IDs that `worktree list --not-archived` prints
#   archived    the IDs that `worktree list --status archived` prints
#   pinned      the IDs that `worktree list --status pinned` prints
#   list-delay  how many lists after `repo open` still leave its worktree out
#   never-list  present when `repo open` never adds its worktree
# `repo open` adds the ID of the path it gets. `worktree unarchive` moves its -w
# ID from archived to listed. `tab new` saves its -i command to
# SHIM_DIR/tab-command and prints TAB_UUID.
cat > "${SHIM_BIN}/supacode" <<'SHIM'
#!/usr/bin/env bash
LC_ALL=C
printf -v call '%s/calls/%04d' "$SHIM_DIR" $(($(find "${SHIM_DIR}/calls" -type f | wc -l) + 1))
for arg in "$@"; do
	printf '%s\0' "$arg"
done > "$call"
printf '%s\n' "${EPOCHREALTIME:-$(date +%s)}" >> "${SHIM_DIR}/call-times"
! grep -qxF -e "$1" -e "$1 ${2-}" "${SHIM_DIR}/fail" 2> /dev/null || exit 1
case "$1 ${2-}" in
"socket "*)
	echo "/tmp/supacode-test/pid-1"
	;;
"worktree list")
	if [[ -s "${SHIM_DIR}/opened" ]]; then
		lists=$(($(cat "${SHIM_DIR}/lists-since-open") + 1))
		echo "$lists" > "${SHIM_DIR}/lists-since-open"
		if ((lists > $(cat "${SHIM_DIR}/list-delay"))); then
			cat "${SHIM_DIR}/opened" >> "${SHIM_DIR}/listed"
			: > "${SHIM_DIR}/opened"
		fi
	fi
	case " $* " in
	*" --status archived "*) cat "${SHIM_DIR}/archived" ;;
	*" --status pinned "*) cat "${SHIM_DIR}/pinned" ;;
	*" --not-archived "*) cat "${SHIM_DIR}/listed" ;;
	*) cat "${SHIM_DIR}/listed" "${SHIM_DIR}/archived" ;;
	esac
	;;
"worktree unarchive")
	id="${4-}"
	grep -vxF -- "$id" "${SHIM_DIR}/archived" > "${SHIM_DIR}/archived.next"
	mv "${SHIM_DIR}/archived.next" "${SHIM_DIR}/archived"
	printf '%s\n' "$id" >> "${SHIM_DIR}/listed"
	;;
"repo open")
	if [[ ! -e "${SHIM_DIR}/never-list" ]]; then
		path="${!#}"
		jq -rn --arg path "${path%/}/" '$path | @uri' > "${SHIM_DIR}/opened"
		echo 0 > "${SHIM_DIR}/lists-since-open"
	fi
	;;
"worktree pin" | "worktree appearance") ;;
"tab new")
	while (($#)); do
		[[ "$1" != -i && "$1" != --input ]] || printf '%s' "${2-}" > "${SHIM_DIR}/tab-command"
		shift
	done
	echo "$TAB_UUID"
	;;
*)
	echo "supacode shim: unexpected arguments: $*" >&2
	exit 64
	;;
esac
SHIM
chmod +x "${SHIM_BIN}/supacode"

# The tree-me shim runs the real tree-me. When SHIM_DIR/hide-tree-me-cd exists, it
# drops the TREE_ME_CD line from the output.
cat > "${SHIM_BIN}/tree-me" <<'SHIM'
#!/usr/bin/env bash
if [[ -e "${SHIM_DIR}/hide-tree-me-cd" ]]; then
	"$TREE_ME" "$@" | grep -v '^TREE_ME_CD:'
	exit "${PIPESTATUS[0]}"
fi
exec "$TREE_ME" "$@"
SHIM
chmod +x "${SHIM_BIN}/tree-me"

# A script that hangs fails its case instead of the whole suite.
WATCHDOG=()
for candidate in timeout gtimeout; do
	if command -v "$candidate" > /dev/null 2>&1; then
		WATCHDOG=("$(command -v "$candidate")" 60)
		break
	fi
done

TAB_SHELLS=(bash)
if command -v zsh > /dev/null 2>&1; then
	TAB_SHELLS+=(zsh)
else
	printf 'SKIP: running the tab command in zsh, because zsh is not installed\n' >&2
fi

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

pass() {
	passes=$((passes + 1))
}

fail() { # message
	failures=$((failures + 1))
	printf 'FAIL: %s\n' "$1" >&2
}

check_eq() { # label actual expected
	if [[ "$2" == "$3" ]]; then
		pass
	else
		fail "$1 (expected '$3', got '$2')"
	fi
}

check() { # label command...
	local label="$1"
	shift
	if "$@"; then
		pass
	else
		fail "$label"
	fi
}

contains() { # haystack needle
	[[ "$1" == *"$2"* ]]
}

configure_repo() { # path
	git -C "$1" config user.name Test &&
		git -C "$1" config user.email test@example.com &&
		git -C "$1" config commit.gpgsign false
}

advance_origin() { # branch message
	{ git -C "$SEED" checkout -q "$1" 2> /dev/null || git -C "$SEED" checkout -q -b "$1" main; } &&
		git -C "$SEED" commit -q --allow-empty -m "$2" &&
		git -C "$SEED" push -q origin "$1"
}

build_repos() {
	git init -q --bare "$ORIGIN" &&
		git -C "$ORIGIN" symbolic-ref HEAD refs/heads/main &&
		git init -q "$SEED" &&
		configure_repo "$SEED" &&
		git -C "$SEED" symbolic-ref HEAD refs/heads/main &&
		git -C "$SEED" commit -q --allow-empty -m first &&
		git -C "$SEED" remote add origin "$ORIGIN" &&
		git -C "$SEED" push -q origin main &&
		git clone -q "$ORIGIN" "$REPO" &&
		configure_repo "$REPO" &&
		git -C "$REPO" remote set-head origin main &&
		advance_origin main second &&
		STALE_MAIN=$(git -C "$REPO" rev-parse refs/remotes/origin/main)
}

# Each case gets a bare origin whose main is one commit ahead of the clone's
# origin/main, a clone with origin/HEAD set, and empty Supacode state. tree-me
# names the repo after the origin URL, so worktrees land in WORKTREE_ROOT/widget.
begin_case() { # name [worktree_root_name]
	CASE_NAME="$1"
	CASE_COUNT=$((CASE_COUNT + 1))
	CASE_DIR="${TEST_ROOT}/case-${CASE_COUNT}"
	ORIGIN="${CASE_DIR}/widget.git"
	SEED="${CASE_DIR}/seed"
	REPO="${CASE_DIR}/widget"
	WORKTREE_ROOT="${CASE_DIR}/${2:-worktrees}"
	SHIM_DIR="${CASE_DIR}/supacode"
	SHIM_CLAUDE_DIR="${CASE_DIR}/claude"
	BRIEF="${CASE_DIR}/brief.md"
	STDOUT_FILE="${CASE_DIR}/stdout"
	STDERR_FILE="${CASE_DIR}/stderr"
	mkdir -p "${SHIM_DIR}/calls" "$SHIM_CLAUDE_DIR"
	: > "${SHIM_DIR}/listed"
	: > "${SHIM_DIR}/archived"
	: > "${SHIM_DIR}/pinned"
	printf '0\n' > "${SHIM_DIR}/list-delay"
	printf '%s\n' "$DEFAULT_BRIEF" > "$BRIEF"
	build_repos || fail "${CASE_NAME}: the fixture repos build"
}

# A caller runs this in a subshell. It moves the subshell to START_DIR, sets the
# fake home, and puts the shims first on PATH. It exports what the shims read.
enter_test_env() {
	cd "$START_DIR" || exit 1
	export HOME="$FAKE_HOME" ZDOTDIR="$FAKE_HOME" PATH="$SHIM_PATH"
	export SHIM_DIR SHIM_CLAUDE_DIR TREE_ME TAB_UUID WORKTREE_ROOT
}

# A caller sets CASE_LIST_TIMEOUT or CASE_CWD for one call with a prefix
# assignment. The default of 10 seconds keeps a script that never sees its
# worktree listed from holding a case for the script's own 30-second default.
# CASE_CWD is the directory the script runs in, which defaults to START_DIR.
run_spawn() { # argument...
	local list_timeout="${CASE_LIST_TIMEOUT-10}" cwd="${CASE_CWD-$START_DIR}"
	(
		enter_test_env
		cd "$cwd" || exit 1
		export SPAWN_TASK_LIST_TIMEOUT="$list_timeout"
		exec ${WATCHDOG[@]+"${WATCHDOG[@]}"} "$SPAWN" "$@"
	) < /dev/null > "$STDOUT_FILE" 2> "$STDERR_FILE"
	STATUS=$?
}

spawn() { # argument...
	run_spawn --repo "$REPO" "$@" --brief "$BRIEF"
}

# Runs the tab's saved command from START_DIR the way the tab's shell would.
# zsh -f skips the developer's startup files, which could put the real claude
# ahead of the shim on PATH.
run_tab_command() { # shell
	local command=""
	rm -f "${SHIM_CLAUDE_DIR}/cwd" "${SHIM_CLAUDE_DIR}/args"
	[[ -f "${SHIM_DIR}/tab-command" ]] && command=$(< "${SHIM_DIR}/tab-command")
	[[ -n "$command" ]] || return 0
	(
		enter_test_env
		if [[ "$1" == zsh ]]; then
			exec zsh -f -c "$command"
		fi
		exec bash -c "$command"
	) < /dev/null > "${CASE_DIR}/tab-output" 2>&1
}

load_received_args() {
	local arg
	RECEIVED_ARGS=()
	[[ -f "${SHIM_CLAUDE_DIR}/args" ]] || return 0
	while IFS= read -r -d '' arg; do
		RECEIVED_ARGS+=("$arg")
	done < "${SHIM_CLAUDE_DIR}/args"
}

expect_claude_args() { # shell expected_cwd expected_argument...
	local label="${CASE_NAME}, in $1" index
	run_tab_command "$1"
	check_eq "${label}: claude runs in the worktree" "$(cat "${SHIM_CLAUDE_DIR}/cwd" 2> /dev/null)" "$2"
	shift 2
	load_received_args
	check_eq "${label}: claude gets $# argument(s)" "${#RECEIVED_ARGS[@]}" "$#"
	index=0
	while (($#)); do
		check_eq "${label}: claude argument $((index + 1))" "${RECEIVED_ARGS[index]-}" "$1"
		index=$((index + 1))
		shift
	done
}

worktree_id() { # path
	jq -rn --arg path "$1/" '$path | @uri'
}

# A missing directory yields text that no recorded cwd can equal.
physical() { # path
	(cd "$1" 2> /dev/null && pwd -P) || printf 'missing directory %s\n' "$1"
}

worktree_path_for() { # branch
	git -C "$REPO" worktree list --porcelain | awk -v target="branch refs/heads/$1" '
		/^worktree / { path = substr($0, 10) }
		$0 == target { print path; exit }
	'
}

worktrees() {
	git -C "$REPO" worktree list --porcelain
}

local_branches() {
	git -C "$REPO" for-each-ref --format='%(refname) %(objectname)' refs/heads
}

all_refs() {
	git -C "$REPO" for-each-ref
}

branch_sha() { # branch
	git -C "$REPO" rev-parse --verify --quiet "refs/heads/$1"
}

origin_sha() { # branch
	git -C "$ORIGIN" rev-parse --verify --quiet "refs/heads/$1"
}

checked_out_branch() { # worktree
	git -C "$1" symbolic-ref --short HEAD 2> /dev/null
}

out_value() { # key
	sed -n "s/^$1=//p" "$STDOUT_FILE" 2> /dev/null
}

output_contains() { # text
	cat "$STDOUT_FILE" "$STDERR_FILE" 2> /dev/null | grep -qF -- "$1"
}

file_lacks() { # path text
	[[ -f "$1" ]] && ! grep -qF -- "$2" "$1"
}

call_files() {
	local file
	for file in "${SHIM_DIR}/calls/"*; do
		[[ -f "$file" ]] && printf '%s\n' "$file"
	done
}

load_call() { # call_file
	local arg
	CALL_ARGS=()
	while IFS= read -r -d '' arg; do
		CALL_ARGS+=("$arg")
	done < "$1"
}

# A call's key is its subcommand, such as "socket" or "worktree pin".
call_key() { # call_file
	load_call "$1"
	if [[ "${CALL_ARGS[0]-}" == socket ]]; then
		printf 'socket\n'
	else
		printf '%s %s\n' "${CALL_ARGS[0]-}" "${CALL_ARGS[1]-}"
	fi
}

call_keys() {
	local file
	while IFS= read -r file; do
		call_key "$file"
	done < <(call_files)
}

calls_to() { # key
	local file
	while IFS= read -r file; do
		[[ "$(call_key "$file")" != "$1" ]] || printf '%s\n' "$file"
	done < <(call_files)
}

supacode_call_count() {
	call_files | wc -l | tr -d ' '
}

call_count() { # key
	calls_to "$1" | wc -l | tr -d ' '
}

# The subcommands in call order, with a run of repeats shown once.
call_order() {
	call_keys | uniq | awk 'NR > 1 { printf ", " } { printf "%s", $0 }'
}

count_after() { # anchor_key key
	call_keys | awk -v anchor="$1" -v key="$2" 'seen && $0 == key { n++ } $0 == anchor { seen = 1 } END { print n + 0 }'
}

# Seconds from the first call to anchor_key to the last call to key after it.
seconds_between() { # anchor_key key
	paste -d '|' <(call_keys) "${SHIM_DIR}/call-times" 2> /dev/null | awk -F '|' -v anchor="$1" -v key="$2" '
		$1 == anchor && start == "" { start = $2 }
		start != "" && $1 == key { end = $2 }
		END { if (start != "" && end != "") print end - start }
	'
}

at_least() { # number minimum
	[[ -n "$1" ]] && awk -v number="$1" -v minimum="$2" 'BEGIN { exit !(number >= minimum) }'
}

# The value after the first of the options in the first call to key.
call_option() { # key option...
	local file index option
	file=$(calls_to "$1" | head -n 1)
	shift
	[[ -n "$file" ]] || return 0
	load_call "$file"
	for ((index = 0; index + 1 < ${#CALL_ARGS[@]}; index++)); do
		for option in "$@"; do
			if [[ "${CALL_ARGS[index]}" == "$option" ]]; then
				printf '%s\n' "${CALL_ARGS[index + 1]}"
				return 0
			fi
		done
	done
}

call_has() { # key argument
	local file arg
	file=$(calls_to "$1" | head -n 1)
	[[ -n "$file" ]] || return 1
	load_call "$file"
	for arg in "${CALL_ARGS[@]}"; do
		[[ "$arg" != "$2" ]] || return 0
	done
	return 1
}

call_last_arg() { # key
	local file
	file=$(calls_to "$1" | head -n 1)
	[[ -n "$file" ]] || return 0
	load_call "$file"
	printf '%s\n' "${CALL_ARGS[${#CALL_ARGS[@]} - 1]}"
}

check "spawn-task.sh exists and is executable" test -x "$SPAWN"

# ── A new branch ─────────────────────────────────────────────────────────────

begin_case "a new branch from the default base"
WT="${WORKTREE_ROOT}/widget/haacked/happy-path"
ID=$(worktree_id "$WT")
check "${CASE_NAME}: the clone's origin/main starts behind origin" test "$STALE_MAIN" != "$(origin_sha main)"
spawn --branch haacked/happy-path
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the worktree is on the new branch" "$(checked_out_branch "$WT")" "haacked/happy-path"
check_eq "${CASE_NAME}: the branch starts at origin's latest main" "$(branch_sha haacked/happy-path)" "$(origin_sha main)"
check "${CASE_NAME}: the brief is copied to .notes/brief.md" cmp -s "$BRIEF" "${WT}/.notes/brief.md"
check_eq "${CASE_NAME}: repo open runs once" "$(call_count "repo open")" "1"
check_eq "${CASE_NAME}: repo open gets the worktree path" "$(call_last_arg "repo open")" "$WT"
check_eq "${CASE_NAME}: a caller outside any worktree means no pin" "$(call_count "worktree pin")" "0"
check_eq "${CASE_NAME}: no --color means no appearance call" "$(call_count "worktree appearance")" "0"
check_eq "${CASE_NAME}: tab new runs once" "$(call_count "tab new")" "1"
check_eq "${CASE_NAME}: tab new gets the worktree ID" "$(call_option "tab new" -w --worktree)" "$ID"
check "${CASE_NAME}: tab new runs in the background" call_has "tab new" --background
check_eq "${CASE_NAME}: the tab title is the worktree's last path component" \
	"$(call_option "tab new" --title)" "happy-path"
check_eq "${CASE_NAME}: supacode calls run in order" "$(call_order)" \
	"socket, worktree list, repo open, worktree list, tab new"
check_eq "${CASE_NAME}: stdout names the worktree" "$(out_value worktree)" "$WT"
check_eq "${CASE_NAME}: stdout names the worktree ID" "$(out_value worktree_id)" "$ID"
check_eq "${CASE_NAME}: stdout names the tab" "$(out_value tab)" "$TAB_UUID"
expect_claude_args bash "$(physical "$WT")" -- "$DEFAULT_BRIEF"

begin_case "no origin/HEAD and no --base"
git -C "$REPO" remote set-head origin -d
spawn --branch no-head
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the branch starts at origin's latest main" "$(branch_sha no-head)" "$(origin_sha main)"

begin_case "--base with a stale origin branch"
advance_origin release "release one"
git -C "$REPO" fetch -q origin
advance_origin release "release two"
spawn --branch on-release --base origin/release
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the branch starts at origin's latest release" "$(branch_sha on-release)" "$(origin_sha release)"

begin_case "--base with a local branch"
git -C "$REPO" checkout -q -b parent-branch &&
	git -C "$REPO" commit -q --allow-empty -m parent &&
	git -C "$REPO" checkout -q main
spawn --branch stacked --base parent-branch
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the branch starts at the base branch" "$(branch_sha stacked)" "$(branch_sha parent-branch)"
check_eq "${CASE_NAME}: the base is recorded as the branch's parent" \
	"$(git -C "$REPO" config --get branch.stacked.parent)" "parent-branch"

begin_case "an unreachable origin"
git -C "$REPO" remote set-url origin "${CASE_DIR}/gone/widget.git"
spawn --branch offline
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names origin" output_contains "origin"
check_eq "${CASE_NAME}: creates no branch" "$(branch_sha offline)" ""
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/offline"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"

begin_case "a --base that origin does not have"
spawn --branch no-base --base origin/no-such-base
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: creates no branch" "$(branch_sha no-base)" ""
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/no-base"

begin_case "--repo in a subdirectory of the work tree"
mkdir -p "${REPO}/src/deep"
WT="${WORKTREE_ROOT}/widget/from-subdir"
run_spawn --repo "${REPO}/src/deep" --branch from-subdir --brief "$BRIEF"
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: stdout names the worktree" "$(out_value worktree)" "$WT"
check "${CASE_NAME}: the brief is copied to .notes/brief.md" cmp -s "$BRIEF" "${WT}/.notes/brief.md"

# ── The tab's command ────────────────────────────────────────────────────────

begin_case "a brief full of shell syntax"
WT="${WORKTREE_ROOT}/widget/quoting"
CANARY_SUBSTITUTION="${CASE_DIR}/canary-substitution"
CANARY_BACKTICK="${CASE_DIR}/canary-backtick"
HARD_BRIEF=$(
	printf '%s\n' \
		"-p leading dash, \"double\" and 'single' quotes, it's" \
		"\$HOME \${HOME} \$(touch ${CANARY_SUBSTITUTION}) \`touch ${CANARY_BACKTICK}\`" \
		'back\slash \n \\ * ? [a] ~ !! 100% ; && | > /dev/null' \
		$'\ttab-indented line with trailing spaces   ' \
		'' \
		"café → the last line ends in a backslash \\"
)
printf '%s\n' "$HARD_BRIEF" > "$BRIEF"
spawn --branch quoting
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check "${CASE_NAME}: the brief is copied byte for byte" cmp -s "$BRIEF" "${WT}/.notes/brief.md"
check "${CASE_NAME}: the tab command does not contain the brief's text" \
	file_lacks "${SHIM_DIR}/tab-command" "leading dash"
for shell in "${TAB_SHELLS[@]}"; do
	expect_claude_args "$shell" "$(physical "$WT")" -- "$HARD_BRIEF"
	check "${CASE_NAME}, in ${shell}: no command substitution in the brief runs" test ! -e "$CANARY_SUBSTITUTION"
	check "${CASE_NAME}, in ${shell}: no backtick command in the brief runs" test ! -e "$CANARY_BACKTICK"
done

begin_case "a worktree root with a space and an apostrophe" "it's a root"
WT="${WORKTREE_ROOT}/widget/spaced"
ID=$(worktree_id "$WT")
spawn --branch spaced
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check "${CASE_NAME}: the ID percent-encodes the space and the apostrophe" \
	contains "$(out_value worktree_id)" "%2Fit%27s%20a%20root%2Fwidget%2Fspaced%2F"
check_eq "${CASE_NAME}: stdout names the worktree ID" "$(out_value worktree_id)" "$ID"
check_eq "${CASE_NAME}: tab new gets the worktree ID" "$(call_option "tab new" -w --worktree)" "$ID"
for shell in "${TAB_SHELLS[@]}"; do
	expect_claude_args "$shell" "$(physical "$WT")" -- "$DEFAULT_BRIEF"
done

begin_case "--plan"
WT="${WORKTREE_ROOT}/widget/planned"
spawn --branch planned --plan
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
expect_claude_args bash "$(physical "$WT")" --permission-mode plan -- "$DEFAULT_BRIEF"

begin_case "--go"
WT="${WORKTREE_ROOT}/widget/going"
spawn --branch going --go
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check "${CASE_NAME}: the brief is copied to .notes/brief.md" cmp -s "$BRIEF" "${WT}/.notes/brief.md"
expect_claude_args bash "$(physical "$WT")" -- "/go --plan-file .notes/brief.md"

# ── Tab appearance ───────────────────────────────────────────────────────────

begin_case "--color"
WT="${WORKTREE_ROOT}/widget/tinted"
ID=$(worktree_id "$WT")
spawn --branch tinted --color teal
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: appearance runs once" "$(call_count "worktree appearance")" "1"
check_eq "${CASE_NAME}: appearance gets the worktree ID" "$(call_option "worktree appearance" -w --worktree)" "$ID"
check_eq "${CASE_NAME}: appearance gets the color" "$(call_option "worktree appearance" --color)" "teal"

begin_case "--color with a hex value"
spawn --branch hex-tinted --color "#1A2b3C80"
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: appearance gets the color" "$(call_option "worktree appearance" --color)" "#1A2b3C80"

begin_case "--title"
spawn --branch titled --title "my task"
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: tab new gets the title" "$(call_option "tab new" --title)" "my task"

# ── Pinning ──────────────────────────────────────────────────────────────────

begin_case "a caller in a pinned worktree"
git -C "$REPO" worktree add -q -b pinned-caller "${CASE_DIR}/pinned-caller"
CALLER=$(worktree_path_for pinned-caller)
mkdir -p "${CALLER}/src"
printf '%s\n' "$(worktree_id "$CALLER")" > "${SHIM_DIR}/pinned"
WT="${WORKTREE_ROOT}/widget/from-pinned"
ID=$(worktree_id "$WT")
CASE_CWD="${CALLER}/src" spawn --branch from-pinned
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: pin runs once" "$(call_count "worktree pin")" "1"
check_eq "${CASE_NAME}: pin gets the new worktree's ID" "$(call_option "worktree pin" -w --worktree)" "$ID"
check "${CASE_NAME}: pin runs in the background" call_has "worktree pin" --background
check_eq "${CASE_NAME}: the tab opens after the pin" "$(call_order)" \
	"socket, worktree list, repo open, worktree list, worktree pin, tab new"

begin_case "a caller in an unpinned worktree"
git -C "$REPO" worktree add -q -b unpinned-caller "${CASE_DIR}/unpinned-caller"
CALLER=$(worktree_path_for unpinned-caller)
printf '%s\n' "$(worktree_id "${CALLER}/nested")" "$(worktree_id "${CASE_DIR}/other")" > "${SHIM_DIR}/pinned"
CASE_CWD="$CALLER" spawn --branch from-unpinned
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: pin does not run" "$(call_count "worktree pin")" "0"
check_eq "${CASE_NAME}: tab new runs once" "$(call_count "tab new")" "1"

begin_case "a caller in the main checkout"
printf '%s\n' "$(worktree_id "${CASE_DIR}/other")" > "${SHIM_DIR}/pinned"
CASE_CWD="$REPO" spawn --branch from-main
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: pin does not run" "$(call_count "worktree pin")" "0"

# ── Supacode listing the worktree ────────────────────────────────────────────

begin_case "a worktree Supacode already lists"
WT="${WORKTREE_ROOT}/widget/listed"
ID=$(worktree_id "$WT")
printf '%s\n' "$(worktree_id "${CASE_DIR}/other")" "$ID" > "${SHIM_DIR}/listed"
spawn --branch listed
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: repo open does not run" "$(call_count "repo open")" "0"
check_eq "${CASE_NAME}: tab new gets the worktree ID" "$(call_option "tab new" -w --worktree)" "$ID"

begin_case "a listed ID that only contains the worktree's ID"
WT="${WORKTREE_ROOT}/widget/decoy"
ID=$(worktree_id "$WT")
printf '%s\n' "$(worktree_id "${WT}/nested")" "$(worktree_id "/elsewhere${WT}")" > "${SHIM_DIR}/listed"
spawn --branch decoy
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: repo open runs once" "$(call_count "repo open")" "1"
check_eq "${CASE_NAME}: tab new gets the worktree ID" "$(call_option "tab new" -w --worktree)" "$ID"

begin_case "a worktree Supacode lists only as archived"
WT="${WORKTREE_ROOT}/widget/archived"
ID=$(worktree_id "$WT")
printf '%s\n' "$ID" > "${SHIM_DIR}/archived"
spawn --branch archived
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: unarchive gets the worktree ID" "$(call_option "worktree unarchive" -w --worktree)" "$ID"
check "${CASE_NAME}: unarchive runs in the background" call_has "worktree unarchive" --background
check_eq "${CASE_NAME}: repo open does not run" "$(call_count "repo open")" "0"
check_eq "${CASE_NAME}: the tab opens only after the unarchive" "$(call_order)" \
	"socket, worktree list, worktree unarchive, worktree list, tab new"
check_eq "${CASE_NAME}: tab new gets the worktree ID" "$(call_option "tab new" -w --worktree)" "$ID"

begin_case "a worktree Supacode lists after two polls"
WT="${WORKTREE_ROOT}/widget/slow"
ID=$(worktree_id "$WT")
printf '2\n' > "${SHIM_DIR}/list-delay"
spawn --branch slow
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: repo open runs once" "$(call_count "repo open")" "1"
check_eq "${CASE_NAME}: polling stops at the first list that names the worktree" \
	"$(count_after "repo open" "worktree list")" "3"
check "${CASE_NAME}: polls wait between lists" at_least "$(seconds_between "repo open" "worktree list")" 1
check_eq "${CASE_NAME}: tab new gets the worktree ID" "$(call_option "tab new" -w --worktree)" "$ID"

begin_case "a worktree Supacode never lists"
touch "${SHIM_DIR}/never-list"
SECONDS=0
CASE_LIST_TIMEOUT=1 spawn --branch unlisted
elapsed=$SECONDS
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: repo open runs once" "$(call_count "repo open")" "1"
check_eq "${CASE_NAME}: pin does not run" "$(call_count "worktree pin")" "0"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"
check "${CASE_NAME}: gives up soon after SPAWN_TASK_LIST_TIMEOUT" test "$elapsed" -le 10
check "${CASE_NAME}: the message names the rerun that finishes it" output_contains "--existing unlisted"

# ── Supacode failures ────────────────────────────────────────────────────────

begin_case "a failing supacode socket"
printf 'socket\n' > "${SHIM_DIR}/fail"
spawn --branch no-socket
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: prints an error to stderr" test -s "$STDERR_FILE"
check_eq "${CASE_NAME}: socket is the only supacode call" "$(call_order)" "socket"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/no-socket"
check_eq "${CASE_NAME}: creates no branch" "$(branch_sha no-socket)" ""

begin_case "a failing supacode tab new"
WT="${WORKTREE_ROOT}/widget/tab-fails"
printf 'tab new\n' > "${SHIM_DIR}/fail"
spawn --branch tab-fails
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: tab new was attempted" "$(call_count "tab new")" "1"
check "${CASE_NAME}: the message names the worktree" output_contains "$WT"
check "${CASE_NAME}: the message names the rerun that finishes it" output_contains "--existing tab-fails"
: > "${SHIM_DIR}/fail"
spawn --existing tab-fails
check_eq "${CASE_NAME}: the rerun exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the rerun reuses the worktree" "$(physical "$(out_value worktree)")" "$(physical "$WT")"
check_eq "${CASE_NAME}: the rerun opens the tab" "$(out_value tab)" "$TAB_UUID"

# ── Branches that exist ──────────────────────────────────────────────────────

begin_case "--branch with a branch that has a worktree"
git -C "$REPO" worktree add -q -b taken "${CASE_DIR}/taken-worktree"
EXISTING=$(worktree_path_for taken)
WORKTREES_BEFORE=$(worktrees)
BRANCHES_BEFORE=$(local_branches)
spawn --branch taken
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names the existing worktree" output_contains "$EXISTING"
check_eq "${CASE_NAME}: adds no worktree" "$(worktrees)" "$WORKTREES_BEFORE"
check_eq "${CASE_NAME}: leaves local branches unchanged" "$(local_branches)" "$BRANCHES_BEFORE"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/taken"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"

begin_case "--branch with a branch that has no worktree"
git -C "$REPO" branch idle
BRANCHES_BEFORE=$(local_branches)
spawn --branch idle
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: the branch still has no worktree" "$(worktree_path_for idle)" ""
check_eq "${CASE_NAME}: leaves local branches unchanged" "$(local_branches)" "$BRANCHES_BEFORE"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/idle"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"

begin_case "--branch with a branch only on origin"
advance_origin remote-taken "another task's work"
WORKTREES_BEFORE=$(worktrees)
spawn --branch remote-taken
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: creates no local branch" "$(branch_sha remote-taken)" ""
check_eq "${CASE_NAME}: adds no worktree" "$(worktrees)" "$WORKTREES_BEFORE"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/remote-taken"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"

begin_case "--existing with the worktree the caller runs in"
git -C "$REPO" worktree add -q -b mine "${CASE_DIR}/mine-worktree"
EXISTING=$(worktree_path_for mine)
mkdir -p "${EXISTING}/.notes"
printf 'This session'"'"'s brief.\n' > "${EXISTING}/.notes/brief.md"
cp "${EXISTING}/.notes/brief.md" "${CASE_DIR}/mine-brief-before"
mkdir -p "${EXISTING}/src"
CASE_CWD="${EXISTING}/src" spawn --existing mine
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names the worktree" output_contains "$EXISTING"
check "${CASE_NAME}: leaves the caller's brief alone" cmp -s "${CASE_DIR}/mine-brief-before" "${EXISTING}/.notes/brief.md"
check_eq "${CASE_NAME}: pin does not run" "$(call_count "worktree pin")" "0"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"

begin_case "--existing with a branch that has a worktree"
git -C "$REPO" worktree add -q -b reuse-me "${CASE_DIR}/reuse-worktree"
EXISTING=$(worktree_path_for reuse-me)
mkdir -p "${EXISTING}/.notes"
printf 'An older brief.\n' > "${EXISTING}/.notes/brief.md"
WORKTREES_BEFORE=$(worktrees)
CASE_CWD="$REPO" spawn --existing reuse-me
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: stdout names the existing worktree" "$(out_value worktree)" "$EXISTING"
check "${CASE_NAME}: the brief replaces the older one" cmp -s "$BRIEF" "${EXISTING}/.notes/brief.md"
check_eq "${CASE_NAME}: adds no worktree" "$(worktrees)" "$WORKTREES_BEFORE"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/reuse-me"
check_eq "${CASE_NAME}: tab new gets the existing worktree's ID" \
	"$(call_option "tab new" -w --worktree)" "$(worktree_id "$EXISTING")"

begin_case "--existing with a branch only on origin"
advance_origin remote-only "remote work"
git -C "$REPO" fetch -q origin
WT="${WORKTREE_ROOT}/widget/remote-only"
spawn --existing remote-only
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: stdout names the new worktree" "$(out_value worktree)" "$WT"
check_eq "${CASE_NAME}: the worktree is on the branch" "$(checked_out_branch "$WT")" "remote-only"
check_eq "${CASE_NAME}: the worktree is at origin's commit" \
	"$(git -C "$WT" rev-parse HEAD 2> /dev/null)" "$(origin_sha remote-only)"
check "${CASE_NAME}: the brief is copied to .notes/brief.md" cmp -s "$BRIEF" "${WT}/.notes/brief.md"

begin_case "--existing with a branch that does not exist"
spawn --existing no-such-branch
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: repo open does not run" "$(call_count "repo open")" "0"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/no-such-branch"

begin_case "tree-me output without a TREE_ME_CD line"
touch "${SHIM_DIR}/hide-tree-me-cd"
spawn --branch hidden
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: tab new does not run" "$(call_count "tab new")" "0"


# ── Argument validation ──────────────────────────────────────────────────────

expect_usage_error() { # argument...
	local refs_before
	refs_before=$(all_refs)
	run_spawn "$@"
	check_eq "${CASE_NAME}: exits 2" "$STATUS" "2"
	check "${CASE_NAME}: prints a message to stderr" test -s "$STDERR_FILE"
	check_eq "${CASE_NAME}: makes no supacode call" "$(supacode_call_count)" "0"
	check "${CASE_NAME}: creates no worktree" test ! -e "$WORKTREE_ROOT"
	check_eq "${CASE_NAME}: leaves the repo's refs unchanged" "$(all_refs)" "$refs_before"
}

begin_case "validation: no --brief"
expect_usage_error --repo "$REPO" --branch task

begin_case "validation: --brief with no value"
expect_usage_error --repo "$REPO" --branch task --brief

begin_case "validation: a brief file that does not exist"
expect_usage_error --repo "$REPO" --branch task --brief "${CASE_DIR}/missing.md"

begin_case "validation: an empty brief file"
: > "${CASE_DIR}/empty.md"
expect_usage_error --repo "$REPO" --branch task --brief "${CASE_DIR}/empty.md"

begin_case "validation: no --repo"
expect_usage_error --branch task --brief "$BRIEF"

begin_case "validation: neither --branch nor --existing"
expect_usage_error --repo "$REPO" --brief "$BRIEF"

begin_case "validation: --branch and --existing together"
expect_usage_error --repo "$REPO" --branch task --existing main --brief "$BRIEF"

begin_case "validation: --base with --existing"
expect_usage_error --repo "$REPO" --existing main --base main --brief "$BRIEF"

begin_case "validation: --plan and --go together"
expect_usage_error --repo "$REPO" --branch task --brief "$BRIEF" --plan --go

begin_case "validation: an unknown flag"
expect_usage_error --repo "$REPO" --branch task --brief "$BRIEF" --colour teal

begin_case "validation: --repo that is not a git repo"
mkdir -p "${CASE_DIR}/plain"
expect_usage_error --repo "${CASE_DIR}/plain" --branch task --brief "$BRIEF"

begin_case "validation: --repo that does not exist"
expect_usage_error --repo "${CASE_DIR}/missing" --branch task --brief "$BRIEF"

begin_case "validation: --repo that is a bare repository"
expect_usage_error --repo "$ORIGIN" --branch task --brief "$BRIEF"

begin_case "validation: a tint Supacode does not have"
expect_usage_error --repo "$REPO" --branch task --brief "$BRIEF" --color pink

begin_case "validation: a hex tint with the wrong length"
expect_usage_error --repo "$REPO" --branch task --brief "$BRIEF" --color "#12345"

printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
[[ "$failures" -eq 0 ]]
