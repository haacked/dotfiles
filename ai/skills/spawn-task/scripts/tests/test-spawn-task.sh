#!/usr/bin/env bash
# Tests for ai/skills/spawn-task/scripts/spawn-task.sh.
#
# Each case builds its own bare origin and clone and runs the real bin/tree-me
# against them. A shim stands in for sb.
#
# Usage: test-spawn-task.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../../../../.." && pwd)"
SPAWN="${SCRIPT_DIR}/../spawn-task.sh"
TREE_ME="${REPO_ROOT}/bin/tree-me"

# The developer's own Switchboard, Claude Code, and git variables would otherwise reach the script.
unset "${!SB_@}" "${!CLAUDE@}" "${!GIT_@}" WORKTREE_ROOT BASH_ENV ENV

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
START_DIR="${TEST_ROOT}/start"
SHIM_BIN="${TEST_ROOT}/bin"
SHIM_PATH="${SHIM_BIN}:${PATH}"
DEFAULT_BRIEF=$'Add a widget to the dashboard.\nThen test it.'
STATUS=0
CASE_COUNT=0
CASE_NAME=""
STALE_MAIN=""
SB_ARGS=()

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

# The sb shim logs each call's arguments, NUL-separated, to its own file in
# SHIM_DIR/sb-calls. With --json, it prints the JSON `sb new --json` prints: the id
# sb-child, the --name, and the folder, which is the --branch's path under
# SHIM_DIR/sb-worktrees when there is a --branch. Lines in SHIM_DIR/fail change it:
#   sb new           exit 1
#   sb new branched  create the --branch in the folder's repo, then exit 1
#   sb prints text   print text instead of JSON
cat > "${SHIM_BIN}/sb" <<'SHIM'
#!/usr/bin/env bash
mkdir -p "${SHIM_DIR}/sb-calls"
printf -v call '%s/sb-calls/%04d' "$SHIM_DIR" $(($(find "${SHIM_DIR}/sb-calls" -type f | wc -l) + 1))
for arg in "$@"; do
	printf '%s\0' "$arg"
done > "$call"
fails() { grep -qxF "$1" "${SHIM_DIR}/fail" 2> /dev/null; }
[[ "$1" == new ]] || { echo "sb shim: unexpected arguments: $*" >&2; exit 64; }
repo="$2" name="" branch="" json=false
while (($#)); do
	case "$1" in
	--name) name="$2" ;;
	--branch) branch="$2" ;;
	--json) json=true ;;
	esac
	shift
done
if fails "sb new branched"; then
	git -C "$repo" branch "$branch"
	echo "sb: refused" >&2
	exit 1
fi
if fails "sb new"; then
	echo "sb: refused" >&2
	exit 1
fi
folder="$repo"
[[ -z "$branch" ]] || folder="${SHIM_DIR}/sb-worktrees/${branch}"
if ! $json || fails "sb prints text"; then
	echo "Created session sb-child"
	exit 0
fi
jq -n --arg name "$name" --arg cwd "$folder" '{id: "sb-child", name: $name, cwd: $cwd}'
SHIM
chmod +x "${SHIM_BIN}/sb"

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
# origin/main, and a clone with origin/HEAD set. tree-me names the repo after
# the origin URL, so its worktrees land in WORKTREE_ROOT/widget.
begin_case() { # name
	CASE_NAME="$1"
	CASE_COUNT=$((CASE_COUNT + 1))
	CASE_DIR="${TEST_ROOT}/case-${CASE_COUNT}"
	ORIGIN="${CASE_DIR}/widget.git"
	SEED="${CASE_DIR}/seed"
	REPO="${CASE_DIR}/widget"
	WORKTREE_ROOT="${CASE_DIR}/worktrees"
	SHIM_DIR="${CASE_DIR}/shims"
	BRIEF="${CASE_DIR}/brief.md"
	STDOUT_FILE="${CASE_DIR}/stdout"
	STDERR_FILE="${CASE_DIR}/stderr"
	mkdir -p "$SHIM_DIR"
	printf '%s\n' "$DEFAULT_BRIEF" > "$BRIEF"
	build_repos || fail "${CASE_NAME}: the fixture repos build"
}

# A caller runs this in a subshell. It moves the subshell to START_DIR, sets the
# fake home, and puts the shims first on PATH. It exports what the shims read.
enter_test_env() {
	cd "$START_DIR" || exit 1
	export HOME="$FAKE_HOME" PATH="$SHIM_PATH"
	export SHIM_DIR TREE_ME WORKTREE_ROOT
}

# A caller sets CASE_CWD for one call with a prefix assignment. It is the
# directory the script runs in, which defaults to START_DIR.
run_spawn() { # argument...
	local cwd="${CASE_CWD-$START_DIR}"
	(
		enter_test_env
		cd "$cwd" || exit 1
		exec ${WATCHDOG[@]+"${WATCHDOG[@]}"} "$SPAWN" "$@"
	) < /dev/null > "$STDOUT_FILE" 2> "$STDERR_FILE"
	STATUS=$?
}

spawn() { # argument...
	run_spawn --repo "$REPO" "$@" --brief "$BRIEF"
}

# A missing directory yields text that no recorded path can equal.
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

sb_call_files() {
	local file
	for file in "${SHIM_DIR}/sb-calls/"*; do
		[[ -f "$file" ]] && printf '%s\n' "$file"
	done
}

sb_call_count() {
	sb_call_files | wc -l | tr -d ' '
}

# The first sb call's arguments load into SB_ARGS.
load_sb_args() {
	local file arg
	SB_ARGS=()
	file=$(sb_call_files | head -n 1)
	[[ -n "$file" ]] || return 0
	while IFS= read -r -d '' arg; do
		SB_ARGS+=("$arg")
	done < "$file"
}

sb_option() { # option
	local index
	load_sb_args
	for ((index = 0; index + 1 < ${#SB_ARGS[@]}; index++)); do
		if [[ "${SB_ARGS[index]}" == "$1" ]]; then
			printf '%s' "${SB_ARGS[index + 1]}"
			return 0
		fi
	done
}

sb_arg() { # index
	load_sb_args
	printf '%s' "${SB_ARGS[$1]-}"
}

sb_has() { # argument
	local arg
	load_sb_args
	for arg in "${SB_ARGS[@]}"; do
		[[ "$arg" != "$1" ]] || return 0
	done
	return 1
}

check "spawn-task.sh exists and is executable" test -x "$SPAWN"

# ── A new branch ─────────────────────────────────────────────────────────────

begin_case "a new branch"
spawn --branch haacked/sb-task --base main --account "$FAKE_HOME"
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: sb runs once" "$(sb_call_count)" "1"
check_eq "${CASE_NAME}: sb new gets the repo as its folder" "$(sb_arg 1)" "$(physical "$REPO")"
check_eq "${CASE_NAME}: sb new gets the branch" "$(sb_option --branch)" "haacked/sb-task"
check_eq "${CASE_NAME}: sb new gets the base" "$(sb_option --base)" "main"
check_eq "${CASE_NAME}: the name is the branch after its last slash" "$(sb_option --name)" "sb-task"
check_eq "${CASE_NAME}: the prompt is the brief" "$(sb_option --prompt)" "$DEFAULT_BRIEF"
check_eq "${CASE_NAME}: sb new gets the account" "$(sb_option --account)" "$(cd "$FAKE_HOME" && pwd)"
check "${CASE_NAME}: --json is an argument" sb_has --json
check_eq "${CASE_NAME}: stdout names the session" "$(out_value session)" "sb-child"
check_eq "${CASE_NAME}: stdout names the name" "$(out_value name)" "sb-task"
check_eq "${CASE_NAME}: stdout names the worktree" "$(out_value worktree)" "${SHIM_DIR}/sb-worktrees/haacked/sb-task"
check "${CASE_NAME}: leaves tree-me out of it" test ! -e "$WORKTREE_ROOT"
check_eq "${CASE_NAME}: creates no branch" "$(branch_sha haacked/sb-task)" ""

begin_case "the default base and --title"
spawn --branch sb-default --title "Short name"
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the base is origin's default branch" "$(sb_option --base)" "origin/main"
check_eq "${CASE_NAME}: --title is the name" "$(sb_option --name)" "Short name"
check_eq "${CASE_NAME}: no --account means none is passed" "$(sb_has --account && echo yes || echo no)" "no"
check "${CASE_NAME}: the clone's origin/main started behind origin" test "$STALE_MAIN" != "$(origin_sha main)"
check_eq "${CASE_NAME}: the base was fetched" "$(git -C "$REPO" rev-parse refs/remotes/origin/main)" "$(origin_sha main)"

begin_case "no origin/HEAD and no --base"
git -C "$REPO" remote set-head origin -d
spawn --branch no-head
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the base is origin's main" "$(sb_option --base)" "origin/main"

begin_case "--base with a stale origin branch"
advance_origin release "release one"
git -C "$REPO" fetch -q origin
advance_origin release "release two"
spawn --branch on-release --base origin/release
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: sb new gets the base" "$(sb_option --base)" "origin/release"
check_eq "${CASE_NAME}: the base was fetched" "$(git -C "$REPO" rev-parse refs/remotes/origin/release)" "$(origin_sha release)"

begin_case "a --base that origin does not have"
spawn --branch no-base --base origin/no-such-base
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

begin_case "a brief that starts with a dash"
printf -- '- First item\n- Second item\n' > "$BRIEF"
spawn --branch sb-dash
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the prompt is the brief" "$(sb_option --prompt)" "$(cat "$BRIEF")"

begin_case "a brief full of shell syntax"
HARD_BRIEF=$(
	printf '%s\n' \
		"-p leading dash, \"double\" and 'single' quotes, it's" \
		"\$HOME \${HOME} \$(touch ${CASE_DIR}/canary) \`touch ${CASE_DIR}/canary\`" \
		'back\slash \n \\ * ? [a] ~ !! 100% ; && | > /dev/null'
)
printf '%s\n' "$HARD_BRIEF" > "$BRIEF"
spawn --branch quoting
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the prompt is the brief, byte for byte" "$(sb_option --prompt)" "$HARD_BRIEF"
check "${CASE_NAME}: no command in the brief runs" test ! -e "${CASE_DIR}/canary"

begin_case "--go"
spawn --branch sb-go --go
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the prompt runs /go on the brief file" "$(sb_option --prompt)" "/go --plan-file $(physical "$CASE_DIR")/brief.md"

begin_case "--go with a relative --brief"
mkdir -p "${CASE_DIR}/rel"
cp "$BRIEF" "${CASE_DIR}/rel/b.md"
CASE_CWD="${CASE_DIR}/rel" run_spawn --repo "$REPO" --branch sb-rel --brief b.md --go
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the prompt names the absolute path" "$(sb_option --prompt)" "/go --plan-file $(physical "${CASE_DIR}/rel")/b.md"

begin_case "--plan"
spawn --branch sb-plan --plan
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check "${CASE_NAME}: the prompt asks for a plan first" contains "$(sb_option --prompt)" "Plan first"
check "${CASE_NAME}: the prompt still holds the brief" contains "$(sb_option --prompt)" "Add a widget to the dashboard."

begin_case "--account relative to the directory the script runs in"
mkdir -p "${CASE_DIR}/cwd/rel-account"
CASE_CWD="${CASE_DIR}/cwd" spawn --branch relative-account --account rel-account
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: sb new gets the absolute path" "$(sb_option --account)" "${CASE_DIR}/cwd/rel-account"

begin_case "--account with a tilde"
mkdir -p "${FAKE_HOME}/.claude-personal"
# The script expands the tilde, so the test passes it unexpanded.
# shellcheck disable=SC2088
spawn --branch tilde-account --account "~/.claude-personal"
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: sb new gets the expanded path" "$(sb_option --account)" "${FAKE_HOME}/.claude-personal"

# ── Failures ─────────────────────────────────────────────────────────────────

begin_case "an unreachable origin"
git -C "$REPO" remote set-url origin "${CASE_DIR}/missing.git"
spawn --branch sb-offline
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names origin" output_contains "origin"
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

begin_case "a failing sb new"
printf 'sb new\n' > "${SHIM_DIR}/fail"
spawn --branch sb-fails
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names sb new" output_contains "sb new failed"
check_eq "${CASE_NAME}: prints no session" "$(out_value session)" ""

begin_case "sb new prints no JSON"
printf 'sb prints text\n' > "${SHIM_DIR}/fail"
spawn --branch sb-text
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message shows sb's output" output_contains "Created session sb-child"
check_eq "${CASE_NAME}: prints no session" "$(out_value session)" ""

begin_case "sb new fails after it creates the branch"
printf 'sb new branched\n' > "${SHIM_DIR}/fail"
spawn --branch sb-half
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names the --existing rerun" output_contains "--existing sb-half"

begin_case "sb is not on PATH"
# The developer's own PATH may hold a real sb, which would start a real session.
mv "${SHIM_BIN}/sb" "${SHIM_BIN}/sb.hidden"
SAVED_SHIM_PATH="$SHIM_PATH"
SHIM_PATH="$SHIM_BIN"
while IFS= read -r -d : path_dir || [[ -n "$path_dir" ]]; do
	[[ -x "${path_dir}/sb" ]] || SHIM_PATH+=":${path_dir}"
done <<< "$PATH"
REFS_BEFORE=$(all_refs)
spawn --branch sb-missing
SHIM_PATH="$SAVED_SHIM_PATH"
mv "${SHIM_BIN}/sb.hidden" "${SHIM_BIN}/sb"
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names sb" output_contains "\`sb\` is not on PATH"
check_eq "${CASE_NAME}: leaves the repo's refs unchanged" "$(all_refs)" "$REFS_BEFORE"

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
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

begin_case "--branch with a branch that has no worktree"
git -C "$REPO" branch idle
BRANCHES_BEFORE=$(local_branches)
spawn --branch idle
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: leaves local branches unchanged" "$(local_branches)" "$BRANCHES_BEFORE"
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

begin_case "--branch with a branch only on origin"
advance_origin remote-taken "another task's work"
spawn --branch remote-taken
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: creates no local branch" "$(branch_sha remote-taken)" ""
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

# ── An existing branch ───────────────────────────────────────────────────────

begin_case "--existing with a branch that has a worktree"
git -C "$REPO" worktree add -q -b reuse-sb "${CASE_DIR}/reuse-sb-worktree"
EXISTING=$(worktree_path_for reuse-sb)
mkdir -p "${EXISTING}/.notes"
printf 'An older brief.\n' > "${EXISTING}/.notes/brief.md"
WORKTREES_BEFORE=$(worktrees)
CASE_CWD="$REPO" spawn --existing reuse-sb --go
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check "${CASE_NAME}: the brief replaces the older one" cmp -s "$BRIEF" "${EXISTING}/.notes/brief.md"
check_eq "${CASE_NAME}: adds no worktree" "$(worktrees)" "$WORKTREES_BEFORE"
check_eq "${CASE_NAME}: sb new gets the worktree as its folder" "$(sb_arg 1)" "$EXISTING"
check_eq "${CASE_NAME}: sb new gets no --branch" "$(sb_has --branch && echo yes || echo no)" "no"
check_eq "${CASE_NAME}: the name is the worktree's folder" "$(sb_option --name)" "reuse-sb-worktree"
check_eq "${CASE_NAME}: the prompt runs /go on the copied brief" "$(sb_option --prompt)" "/go --plan-file .notes/brief.md"

begin_case "--existing without --go"
git -C "$REPO" worktree add -q -b reuse-sb2 "${CASE_DIR}/reuse-sb2-worktree"
CASE_CWD="$REPO" spawn --existing reuse-sb2
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check "${CASE_NAME}: the prompt points at the brief" contains "$(sb_option --prompt)" ".notes/brief.md"

begin_case "--existing with a branch only on origin"
advance_origin remote-only "remote work"
git -C "$REPO" fetch -q origin
WT="${WORKTREE_ROOT}/widget/remote-only"
spawn --existing remote-only
check_eq "${CASE_NAME}: exits 0" "$STATUS" "0"
check_eq "${CASE_NAME}: the worktree is on the branch" "$(checked_out_branch "$WT")" "remote-only"
check_eq "${CASE_NAME}: the worktree is at origin's commit" \
	"$(git -C "$WT" rev-parse HEAD 2> /dev/null)" "$(origin_sha remote-only)"
check "${CASE_NAME}: the brief is copied to .notes/brief.md" cmp -s "$BRIEF" "${WT}/.notes/brief.md"
check_eq "${CASE_NAME}: sb new gets the new worktree" "$(sb_arg 1)" "$WT"

begin_case "--existing with a branch that does not exist"
spawn --existing no-such-branch
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"
check "${CASE_NAME}: creates no worktree directory" test ! -e "${WORKTREE_ROOT}/widget/no-such-branch"

begin_case "--existing with the worktree the caller runs in"
git -C "$REPO" worktree add -q -b mine "${CASE_DIR}/mine-worktree"
EXISTING=$(worktree_path_for mine)
mkdir -p "${EXISTING}/.notes" "${EXISTING}/src"
printf 'This session'"'"'s brief.\n' > "${EXISTING}/.notes/brief.md"
cp "${EXISTING}/.notes/brief.md" "${CASE_DIR}/mine-brief-before"
CASE_CWD="${EXISTING}/src" spawn --existing mine
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names the worktree" output_contains "$EXISTING"
check "${CASE_NAME}: leaves the caller's brief alone" cmp -s "${CASE_DIR}/mine-brief-before" "${EXISTING}/.notes/brief.md"
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

begin_case "--existing when sb new fails"
git -C "$REPO" worktree add -q -b fail-sb "${CASE_DIR}/fail-sb-worktree"
printf 'sb new\n' > "${SHIM_DIR}/fail"
CASE_CWD="$REPO" spawn --existing fail-sb
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check "${CASE_NAME}: the message names the rerun" output_contains "--existing fail-sb"

begin_case "tree-me output without a TREE_ME_CD line"
touch "${SHIM_DIR}/hide-tree-me-cd"
git -C "$REPO" branch hidden
spawn --existing hidden
check_eq "${CASE_NAME}: exits 1" "$STATUS" "1"
check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"

# ── Argument validation ──────────────────────────────────────────────────────

expect_usage_error() { # argument...
	local refs_before
	refs_before=$(all_refs)
	run_spawn "$@"
	check_eq "${CASE_NAME}: exits 2" "$STATUS" "2"
	check "${CASE_NAME}: prints a message to stderr" test -s "$STDERR_FILE"
	check_eq "${CASE_NAME}: sb does not run" "$(sb_call_count)" "0"
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

begin_case "validation: --account that is not a directory"
expect_usage_error --repo "$REPO" --branch task --brief "$BRIEF" --account "${CASE_DIR}/missing"

printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
[[ "$failures" -eq 0 ]]
