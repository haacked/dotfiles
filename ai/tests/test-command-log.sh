#!/usr/bin/env bash
# Tests for ai/bin/log-command.sh, the hook that appends one JSONL entry per
# workflow command.
#
# Two properties dominate. First, silence: UserPromptSubmit stdout is injected
# into the session as context, so a single byte on stdout ends up in every
# prompt. Second, containment: the branch and the origin-derived org/repo become
# path components, so nothing may be written outside the state root.
#
# Usage: test-command-log.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
WRITER="${REPO_ROOT}/ai/bin/log-command.sh"

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
XDG_STATE="${FAKE_HOME}/.local/state"
STATE_ROOT="${XDG_STATE}/ran"
NEUTRAL_CWD="${TEST_ROOT}/neutral"
STDOUT_FILE="${TEST_ROOT}/stdout"
STDERR_FILE="${TEST_ROOT}/stderr"
SESSION_ID="3dc249e3-f567-4637-9884-4794bff65b7f"
WRITER_STATUS=0

mkdir -p "$FAKE_HOME" "$NEUTRAL_CWD"
ln -s "$REPO_ROOT" "$FAKE_HOME/.dotfiles"

# An inherited state-directory override would send every write outside the fake
# HOME these assertions read from.
unset RAN_STATE_DIR

# Keep fixture repos away from the real git config: a global commit.gpgsign or
# init.defaultBranch would otherwise change what the fixtures produce.
export GIT_CONFIG_GLOBAL="${TEST_ROOT}/gitconfig"
export GIT_CONFIG_SYSTEM=/dev/null
: > "$GIT_CONFIG_GLOBAL"
export GIT_AUTHOR_NAME="Test" GIT_AUTHOR_EMAIL="test@example.com"
export GIT_COMMITTER_NAME="Test" GIT_COMMITTER_EMAIL="test@example.com"

cleanup() {
	rm -rf "$TEST_ROOT" 2>/dev/null || rm -rf "$TEST_ROOT" 2>/dev/null
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

check_matches() { # description actual regex
	if [[ "$2" =~ $3 ]]; then
		pass
	else
		fail "$1"
		echo "  [$2] does not match /$3/"
	fi
}

summary() {
	echo ""
	echo "Passed: ${passes}, Failed: ${failures}"
}

make_repo() { # name origin_url [branch] -> prints repo path
	local dir="${TEST_ROOT}/repos/$1"
	mkdir -p "$dir"
	git -C "$dir" init -q -b main
	git -C "$dir" remote add origin "$2"
	git -C "$dir" commit -q --allow-empty -m "base"
	if [[ -n "${3:-}" ]]; then
		git -C "$dir" checkout -q -b "$3"
	fi
	printf '%s\n' "$dir"
}

prompt_payload() { # cwd prompt [agent_id]
	local agent="${3:-}"
	jq -n --arg cwd "$1" --arg prompt "$2" --arg sid "$SESSION_ID" --arg agent "$agent" \
		'{session_id: $sid, transcript_path: "/dev/null", cwd: $cwd,
		  prompt_id: "8014abcd", permission_mode: "default",
		  hook_event_name: "UserPromptSubmit", prompt: $prompt}
		 + (if $agent == "" then {} else {agent_id: $agent} end)'
}

# The captured PostToolUse excerpt in the plan elides session_id and cwd, but the
# writer resolves git state from .cwd, so both are supplied here.
skill_payload() { # cwd skill [args]
	jq -n --arg cwd "$1" --arg skill "$2" --arg args "${3:-}" --arg sid "$SESSION_ID" \
		'{session_id: $sid, transcript_path: "/dev/null", cwd: $cwd,
		  hook_event_name: "PostToolUse", tool_name: "Skill",
		  tool_input: {skill: $skill, args: $args}}'
}

# The process cwd is deliberately a non-repo directory: the writer must resolve
# org, repo, branch, and sha from the payload's .cwd, never from where it runs.
run_writer() { # payload
	: > "$STDOUT_FILE"
	: > "$STDERR_FILE"
	(
		cd "$NEUTRAL_CWD" || exit 1
		printf '%s' "$1" | HOME="$FAKE_HOME" XDG_STATE_HOME="$XDG_STATE" "$WRITER"
	) > "$STDOUT_FILE" 2> "$STDERR_FILE"
	WRITER_STATUS=$?
}

reset_state() {
	rm -rf "$XDG_STATE"
}

state_files() {
	find "$XDG_STATE" -type f 2>/dev/null | sort
}

state_file_count() {
	state_files | grep -c . || true
}

stdout_bytes() {
	wc -c < "$STDOUT_FILE" | tr -d '[:space:]'
}

line_count() { # path
	if [[ -f "$1" ]]; then
		grep -c . < "$1" || true
	else
		printf 'no-such-file\n'
	fi
}

field() { # path jq_expression
	jq -r "$2" < "$1" 2>/dev/null
}

is_json() { # path
	jq -e . "$1" >/dev/null 2>&1
}

contains() { # haystack needle
	[[ "$1" == *"$2"* ]]
}

# Every assertion below is meaningless without the script, so stop here rather
# than emit two dozen failures that all mean the same thing.
if [[ ! -x "$WRITER" ]]; then
	fail "ai/bin/log-command.sh exists and is executable (implementation not written yet)"
	summary
	exit 1
fi

REPO=$(make_repo tracked "git@github.com:haacked/dotfiles.git" "haacked/breadcrumbs")
REPO_SHA=$(git -C "$REPO" rev-parse --short HEAD)
# A branch name with a slash lands here, sanitized to a dash.
LOG_PATH="${STATE_ROOT}/haacked/dotfiles/haacked-breadcrumbs.jsonl"

# ── A tracked typed command ──────────────────────────────────────────────────

reset_state
run_writer "$(prompt_payload "$REPO" "/simplify")"

check_eq "typed tracked command exits 0" "$WRITER_STATUS" "0"
check_eq "typed tracked command prints nothing on stdout" "$(stdout_bytes)" "0"
check_eq "typed tracked command writes exactly one file" "$(state_file_count)" "1"
check_eq "slashed branch name lands in the sanitized path" "$(state_files)" "$LOG_PATH"
check_eq "one invocation writes exactly one line" "$(line_count "$LOG_PATH")" "1"
check "the line is valid JSON" is_json "$LOG_PATH"
check_eq "step is the canonical name" "$(field "$LOG_PATH" .step)" "simplify"
check_eq "command is the raw invocation" "$(field "$LOG_PATH" .command)" "/simplify"
check_eq "source marks a typed command" "$(field "$LOG_PATH" .source)" "typed"
check_eq "sha is HEAD of the payload's cwd" "$(field "$LOG_PATH" .sha)" "$REPO_SHA"
check_matches "ts is an ISO 8601 UTC stamp" "$(field "$LOG_PATH" .ts)" \
	'^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$'
check_eq "a main-context call records no agent" "$(field "$LOG_PATH" .agent)" "null"

# The plan's example line shows "3dc249e3" against a session_id of "0bfd…", so
# whether the field is the full id or its leading segment is unsettled. Both
# satisfy this; an empty or unrelated value does not.
session_field=$(field "$LOG_PATH" .session)
check "session is recorded" test -n "$session_field"
check "session identifies this session" \
	test "${SESSION_ID:0:${#session_field}}" = "$session_field"

# ── Append-only ──────────────────────────────────────────────────────────────

run_writer "$(prompt_payload "$REPO" "/commit")"
check_eq "a second command appends rather than replaces" "$(line_count "$LOG_PATH")" "2"
check_eq "the branch keeps one file" "$(state_file_count)" "1"
check_eq "the appended line carries its own step" \
	"$(sed -n '2p' "$LOG_PATH" | jq -r .step)" "commit"

# ── Subagent attribution ─────────────────────────────────────────────────────

reset_state
run_writer "$(prompt_payload "$REPO" "/simplify" "sub-agent-7")"
check_eq "a subagent call records its agent id" "$(field "$LOG_PATH" .agent)" "sub-agent-7"

# ── Command-to-step mapping ──────────────────────────────────────────────────

reset_state
run_writer "$(prompt_payload "$REPO" "/review-code --fix")"
check_eq "arguments do not change the step" "$(field "$LOG_PATH" .step)" "review-code"
check "the command names the invocation that was typed" \
	contains "$(field "$LOG_PATH" .command)" "/review-code"

reset_state
run_writer "$(prompt_payload "$REPO" "/code-review")"
check_eq "the code-review alias maps to review-code" "$(field "$LOG_PATH" .step)" "review-code"

reset_state
run_writer "$(prompt_payload "$REPO" "/address-pr-reviews")"
check_eq "address-pr-reviews maps to itself" "$(field "$LOG_PATH" .step)" "address-pr-reviews"

# ── The PostToolUse shape ────────────────────────────────────────────────────

reset_state
run_writer "$(skill_payload "$REPO" "commit")"
check_eq "a model-invoked skill exits 0" "$WRITER_STATUS" "0"
check_eq "a model-invoked skill prints nothing on stdout" "$(stdout_bytes)" "0"
check_eq "a model-invoked skill writes exactly one line" "$(line_count "$LOG_PATH")" "1"
check_eq "tool_input.skill maps to the canonical step" "$(field "$LOG_PATH" .step)" "commit"
check_eq "a model-invoked skill records HEAD" "$(field "$LOG_PATH" .sha)" "$REPO_SHA"

# The plan names "typed" but never names the value for the other path; only its
# job of telling the two apart is specified.
skill_source=$(field "$LOG_PATH" .source)
check "a model-invoked skill records a source" test -n "$skill_source"
check "a model-invoked skill is distinguishable from a typed one" \
	test "$skill_source" != "typed"
check "the command names the skill invoked" \
	contains "$(field "$LOG_PATH" .command)" "commit"

reset_state
run_writer "$(skill_payload "$REPO" "code-review" "--fix")"
check_eq "Skill(code-review) maps to review-code" "$(field "$LOG_PATH" .step)" "review-code"

# ── Untracked input writes nothing ───────────────────────────────────────────

untracked() { # description payload
	reset_state
	run_writer "$2"
	check_eq "$1 exits 0" "$WRITER_STATUS" "0"
	check_eq "$1 prints nothing on stdout" "$(stdout_bytes)" "0"
	check_eq "$1 writes nothing" "$(state_file_count)" "0"
}

untracked "an unlisted slash command" "$(prompt_payload "$REPO" "/status")"
untracked "a prompt that is not a command" "$(prompt_payload "$REPO" "make the tests faster")"
untracked "a command that merely starts with a tracked name" \
	"$(prompt_payload "$REPO" "/simplifyx")"
untracked "a tracked name mentioned mid-prompt" \
	"$(prompt_payload "$REPO" "should I run /simplify here?")"
untracked "an unlisted skill" "$(skill_payload "$REPO" "followup" "list")"

# ── Degenerate git and payload states ────────────────────────────────────────

untracked "a non-git cwd" "$(prompt_payload "$NEUTRAL_CWD" "/simplify")"

NON_GITHUB=$(make_repo gitlab "git@gitlab.com:org/repo.git" "haacked/breadcrumbs")
untracked "an origin that is not GitHub" "$(prompt_payload "$NON_GITHUB" "/simplify")"

DETACHED=$(make_repo detached "git@github.com:haacked/dotfiles.git")
git -C "$DETACHED" commit -q --allow-empty -m second
git -C "$DETACHED" checkout -q --detach HEAD
untracked "a detached HEAD, which has no branch name" \
	"$(prompt_payload "$DETACHED" "/simplify")"

untracked "malformed stdin" '{"hook_event_name": "UserPromptSubmit", "prompt"'
untracked "empty stdin" ""

# ── Containment ──────────────────────────────────────────────────────────────
# git refuses to resolve a HEAD naming a ref with "..", so the branch cannot
# carry the traversal; corrupting HEAD is the closest reachable approximation
# and pins that the writer stays silent rather than crashing.

TRAVERSAL=$(make_repo traversal "git@github.com:haacked/dotfiles.git" "haacked/breadcrumbs")
printf 'ref: refs/heads/haacked/../../../../evil\n' > "${TRAVERSAL}/.git/HEAD"
untracked "a HEAD naming a ref with .." "$(prompt_payload "$TRAVERSAL" "/simplify")"

# derive_org_repo accepts ".." as the org, so the origin URL is the reachable
# traversal vector. Rejecting it or sanitizing it both satisfy this; escaping
# the state root does not.
reset_state
DOTDOT_ORG=$(make_repo dotdot "git@github.com:../evil.git" "haacked/breadcrumbs")
run_writer "$(prompt_payload "$DOTDOT_ORG" "/simplify")"
check_eq "a traversing origin exits 0" "$WRITER_STATUS" "0"
check_eq "a traversing origin prints nothing on stdout" "$(stdout_bytes)" "0"
check_eq "a traversing origin writes nothing outside the state root" \
	"$(state_files | grep -cv "^${STATE_ROOT}/" || true)" "0"

# ── .cwd beats the process cwd ───────────────────────────────────────────────
# Both repos are real git checkouts with different origins, so an implementation
# reading `pwd` instead of .cwd files the entry under the wrong repo.

reset_state
OTHER=$(make_repo other "git@github.com:PostHog/posthog.git" "haacked/elsewhere")
(
	cd "$OTHER" || exit 1
	printf '%s' "$(prompt_payload "$REPO" "/simplify")" \
		| HOME="$FAKE_HOME" XDG_STATE_HOME="$XDG_STATE" "$WRITER"
) > "$STDOUT_FILE" 2> "$STDERR_FILE"
check_eq "the payload's cwd decides the log path, not the process cwd" \
	"$(state_files)" "$LOG_PATH"

# ── Nothing anywhere but the state root ──────────────────────────────────────

check_eq "the writer created no files outside ~/.local/state/ran" \
	"$(find "$FAKE_HOME" -type f -not -path "${STATE_ROOT}/*" 2>/dev/null | grep -c . || true)" "0"

# ── The step vocabulary cannot drift out of the repo ─────────────────────────
#
# A renamed skill that nobody updates here reports "never run" forever, which is
# indistinguishable from a step genuinely skipped: the one failure mode this
# feature cannot afford. The allowlist covers the names with no directory to
# check: `simplify` and `code-review` ship inside Claude Code, `review-code`
# lives in ~/.agents/skills, and `implement` is read off the branch's commits.

# shellcheck source=../helpers/command-steps.sh
. "${REPO_ROOT}/ai/helpers/command-steps.sh"

EXTERNAL_STEP_NAMES="simplify code-review review-code implement"

for candidate in simplify comment-cleanup commit create-pr review-code code-review \
	review-fix-cycle address-pr-reviews ci-monitor explain-open go; do
	emitted=$(canonical_step "$candidate") || emitted=""
	if [[ -z "$emitted" ]]; then
		fail "canonical_step maps /$candidate to a step"
		continue
	fi
	if [[ -d "${REPO_ROOT}/ai/skills/${emitted}" ]] || printf '%s\n' $EXTERNAL_STEP_NAMES | grep -Fxq "$emitted"; then
		pass
	else
		fail "canonical_step emits '$emitted', which is neither a skill directory nor an allowlisted external name"
	fi
done

for declared in "${COMMAND_STEP_ORDER[@]}"; do
	if [[ -d "${REPO_ROOT}/ai/skills/${declared}" ]] || printf '%s\n' $EXTERNAL_STEP_NAMES | grep -Fxq "$declared"; then
		pass
	else
		fail "COMMAND_STEP_ORDER names '$declared', which is neither a skill directory nor an allowlisted external name"
	fi
done

summary
[[ "${failures}" -eq 0 ]]
