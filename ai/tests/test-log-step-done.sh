#!/usr/bin/env bash
# Tests for ai/bin/log-step-done.sh, which a skill calls as its last action so
# the log records that a step finished rather than that a command was submitted.
#
# The property that matters here is the opposite of the hook's. log-command.sh
# is best-effort and silent because it runs on every prompt; this runs from a
# SKILL.md step, where a wrong name is a typo, so every rejection has to be loud
# and non-zero. A silent exit 0 would turn that typo into a step reading "never
# ran" forever with nothing to show why.
#
# Usage: test-log-step-done.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WRITER="${REPO_ROOT}/ai/bin/log-step-done.sh"

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
STATE_ROOT="${FAKE_HOME}/.local/state/ran"
STDOUT_FILE="${TEST_ROOT}/stdout"
STDERR_FILE="${TEST_ROOT}/stderr"
SHIM_BIN="${TEST_ROOT}/bin"
GH_CALLS="${TEST_ROOT}/gh-calls"
WRITER_STATUS=0
WRITER_ENV=()

mkdir -p "$FAKE_HOME" "$SHIM_BIN"

# The detached-HEAD tier of resolve_branch_name asks GitHub which PR has HEAD as
# its head commit. This shim answers from GH_API_JSON and logs the call, so the
# suite stays offline and can assert the attached path never reaches here.
cat > "${SHIM_BIN}/gh" <<'SHIM'
#!/usr/bin/env bash
printf '%s\n' "$1" >> "$CALLS"
[ "$1" = api ] || exit 1
printf '%s' "${GH_API_JSON-[]}" | jq -r "${4-.}"
SHIM
chmod +x "${SHIM_BIN}/gh"

unset RAN_STATE_DIR

export GIT_CONFIG_GLOBAL="${TEST_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"

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

make_repo() { # name origin branch
	local dir="${TEST_ROOT}/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q
	git -C "$dir" remote add origin "$2"
	git -C "$dir" commit -q --allow-empty -m "first"
	git -C "$dir" checkout -q -b "$3"
	printf '%s\n' "$dir"
}

run_writer() { # repo [args...]
	local repo="$1"
	shift
	: > "$STDOUT_FILE"
	: > "$STDERR_FILE"
	: > "$GH_CALLS"
	(
		cd "$repo" || exit 1
		PATH="${SHIM_BIN}:${PATH}" CALLS="$GH_CALLS" HOME="$FAKE_HOME" \
			env "${WRITER_ENV[@]}" "$WRITER" "$@"
	) > "$STDOUT_FILE" 2> "$STDERR_FILE"
	WRITER_STATUS=$?
	WRITER_ENV=()
}

state_files() {
	find "$STATE_ROOT" -type f 2>/dev/null | sort
}

line_count() { # path
	wc -l < "$1" | tr -d ' '
}

field() { # path jq_expression
	jq -r "$2" < "$1" 2>/dev/null
}

stderr_bytes() {
	wc -c < "$STDERR_FILE" | tr -d ' '
}

if [[ ! -x "$WRITER" ]]; then
	fail "ai/bin/log-step-done.sh exists and is executable"
	printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
	exit 1
fi

REPO=$(make_repo repo "git@github.com:haacked/dotfiles.git" "haacked/breadcrumbs")
REPO_SHA=$(git -C "$REPO" rev-parse --short HEAD)
LOG_PATH="${STATE_ROOT}/haacked/dotfiles/haacked-breadcrumbs.jsonl"

# ── A completion record ──────────────────────────────────────────────────────

run_writer "$REPO" review-code

check_eq "recording a finished step exits 0" "$WRITER_STATUS" "0"
check_eq "it writes one line" "$(line_count "$LOG_PATH")" "1"
check_eq "it lands on the same path the hook writes" "$(state_files)" "$LOG_PATH"
check_eq "status marks the step finished" "$(field "$LOG_PATH" .status)" "done"
check_eq "step is the name it was given" "$(field "$LOG_PATH" .step)" "review-code"
check_eq "sha is HEAD" "$(field "$LOG_PATH" .sha)" "$REPO_SHA"
check_eq "branch is the current branch" "$(field "$LOG_PATH" .branch)" "haacked/breadcrumbs"
check_eq "there is no command, since no command was typed" \
	"$(field "$LOG_PATH" .command)" "null"
check "an attached branch never asks GitHub for one" test ! -s "$GH_CALLS"

# Appending matters as much here as in the hook: the completion record has to
# join the invocation rather than replace the branch's history.
run_writer "$REPO" address-pr-reviews
check_eq "a second record appends" "$(line_count "$LOG_PATH")" "2"
check_eq "the appended line carries its own step" \
	"$(sed -n '2p' "$LOG_PATH" | jq -r .step)" "address-pr-reviews"

# ── Loud rejection ───────────────────────────────────────────────────────────
# Each of these is a SKILL.md typo or a broken environment. Exiting 0 would hide
# it until someone noticed a step that never goes green.

BEFORE=$(line_count "$LOG_PATH")

run_writer "$REPO" not-a-step
check "an unknown step fails" test "$WRITER_STATUS" -ne 0
check "an unknown step explains itself on stderr" test "$(stderr_bytes)" -gt 0
check_eq "an unknown step writes nothing" "$(line_count "$LOG_PATH")" "$BEFORE"

run_writer "$REPO"
check "a missing argument fails" test "$WRITER_STATUS" -ne 0
check_eq "a missing argument writes nothing" "$(line_count "$LOG_PATH")" "$BEFORE"

run_writer "$REPO" review-code extra
check "a second argument fails" test "$WRITER_STATUS" -ne 0
check_eq "a second argument writes nothing" "$(line_count "$LOG_PATH")" "$BEFORE"

# `explain-open` and `go` are commands canonical_step recognizes but the step
# table does not rank. Recording one as finished would invent a row.
run_writer "$REPO" go
check "a command that is not a pipeline step fails" test "$WRITER_STATUS" -ne 0
check_eq "it writes nothing" "$(line_count "$LOG_PATH")" "$BEFORE"

NON_REPO="${TEST_ROOT}/not-a-repo"
mkdir -p "$NON_REPO"
run_writer "$NON_REPO" review-code
check "running outside a repository fails" test "$WRITER_STATUS" -ne 0
check "running outside a repository explains itself" test "$(stderr_bytes)" -gt 0

NON_GITHUB=$(make_repo elsewhere "git@gitlab.com:haacked/thing.git" "haacked/x")
run_writer "$NON_GITHUB" review-code
check "a non-GitHub origin fails" test "$WRITER_STATUS" -ne 0

# ── Detached HEAD ────────────────────────────────────────────────────────────
# An agent harness checks the PR head out detached, so there is no branch name
# to record against. The record has to land on the branch an attended run on the
# same work would write, or /ran and /go never see the completed pass.

DETACHED=$(make_repo detached "git@github.com:haacked/dotfiles.git" "haacked/tmp")
git -C "$DETACHED" checkout -q --detach HEAD
DETACHED_SHA=$(git -C "$DETACHED" rev-parse HEAD)
DETACHED_SHORT=$(git -C "$DETACHED" rev-parse --short HEAD)

WRITER_ENV=(RAN_BRANCH=haacked/from-env)
run_writer "$DETACHED" review-code
ENV_LOG="${STATE_ROOT}/haacked/dotfiles/haacked-from-env.jsonl"
check_eq "a detached HEAD with RAN_BRANCH exits 0" "$WRITER_STATUS" "0"
check_eq "it records against the branch RAN_BRANCH names" \
	"$(field "$ENV_LOG" .branch)" "haacked/from-env"
check_eq "it still records HEAD's sha" "$(field "$ENV_LOG" .sha)" "$DETACHED_SHORT"
check "RAN_BRANCH skips the GitHub lookup" test ! -s "$GH_CALLS"

PR_JSON=$(jq -n -c --arg sha "$DETACHED_SHA" \
	'[{head: {sha: $sha, ref: "haacked/from-pr"}, state: "open"}]')
WRITER_ENV=(GH_API_JSON="$PR_JSON")
run_writer "$DETACHED" review-code
PR_LOG="${STATE_ROOT}/haacked/dotfiles/haacked-from-pr.jsonl"
check_eq "a detached HEAD resolves the branch from its PR" "$WRITER_STATUS" "0"
check_eq "it records against the PR's head ref" \
	"$(field "$PR_LOG" .branch)" "haacked/from-pr"

BEFORE_DETACHED=$(state_files | wc -l | tr -d ' ')
WRITER_ENV=(GH_API_JSON='[]')
run_writer "$DETACHED" review-code
check "a detached HEAD with no PR fails" test "$WRITER_STATUS" -ne 0
check "it explains itself on stderr" test "$(stderr_bytes)" -gt 0
check_eq "it writes nothing" "$(state_files | wc -l | tr -d ' ')" "$BEFORE_DETACHED"

# ── Containment ──────────────────────────────────────────────────────────────
# The org, repo, and branch become path components here exactly as they do in
# the hook, so the same traversal guard has to hold.

TRAVERSAL=$(make_repo traversal "git@github.com:../evil/repo.git" "haacked/x")
run_writer "$TRAVERSAL" review-code
check "an org that would escape the state root fails" test "$WRITER_STATUS" -ne 0
check_eq "nothing was written outside the state root" \
	"$(find "$TEST_ROOT" -name '*.jsonl' -not -path "${STATE_ROOT}/*" | wc -l | tr -d ' ')" "0"

printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
[[ "${failures}" -eq 0 ]]
