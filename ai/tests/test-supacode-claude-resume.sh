#!/usr/bin/env bash
# Tests for ai/bin/supacode-claude-resume.sh.
#
# The property that matters most is that a malformed record never reaches
# `claude --resume`. Restore deletes a record it cannot trust instead of running it.
#
# Usage: test-supacode-claude-resume.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RESUME="${REPO_ROOT}/ai/bin/supacode-claude-resume.sh"

# The developer's own Claude Code and Supacode variables would otherwise reach the script.
unset "${!SUPACODE_@}" "${!CLAUDE@}"

passes=0
failures=0
TEST_ROOT=$(mktemp -d) || exit 1
FAKE_HOME="${TEST_ROOT}/home"
STATE_DIR="${FAKE_HOME}/.local/state/claude-resume"
SESSIONS_DIR="${FAKE_HOME}/.claude/sessions"
TRANSCRIPT_DIR="${FAKE_HOME}/.claude/projects/-project"
SHIM_BIN="${TEST_ROOT}/bin"
SHIM_PATH="${SHIM_BIN}:${PATH}"
START_DIR="${TEST_ROOT}/start"
PROJECT_DIR="${TEST_ROOT}/project/sub"
CALLS="${TEST_ROOT}/claude-calls"
STDIN_FILE="${TEST_ROOT}/stdin"
KEYPRESS_FILE="${TEST_ROOT}/keypress"
IDLE_FIFO="${TEST_ROOT}/idle"
STDOUT_FILE="${TEST_ROOT}/stdout"
STDERR_FILE="${TEST_ROOT}/stderr"
SHIM_DIR="${TEST_ROOT}/supacode"
WORKTREE_DIR="${TEST_ROOT}/project"
SIBLING_DIR="${TEST_ROOT}/project-other"
SPACED_WORKTREE="${TEST_ROOT}/spaced worktree"
QUOTED_DIR="${WORKTREE_DIR}/it's a dir"
STATUS=0
LIVE_PID=""

SURFACE="8DA2BAC1-73BB-4F5D-B8B5-F458AD9FFB8E"
OTHER_SURFACE="5E7D9C3A-2B4F-4A61-9D8E-7C6B5A4F3E2D"
LOWER_SURFACE="c4f1e2d3-a5b6-4c7d-8e9f-0a1b2c3d4e5f"
SID_A="702bd8a4-524b-40cc-b3b7-b6b99f83e45f"
SID_B="3f6c2b1e-9a4d-4e8b-8c7f-1d2e3f4a5b6c"
SID_C="e1d2c3b4-a5f6-4789-8abc-def012345678"
SID_UNRELATED="9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
RECORD="${STATE_DIR}/${SURFACE}.json"
LOWER_RECORD="${STATE_DIR}/${LOWER_SURFACE}.json"
TRANSCRIPT_A="${TRANSCRIPT_DIR}/${SID_A}.jsonl"
OLD_SOCKET="/tmp/supacode-501/pid-1001"
RUNNING_SOCKET="/tmp/supacode-501/pid-1002"
OTHER_RUNNING_SOCKET="/tmp/supacode-501/pid-1003"
ENDED_AT=$(($(date +%s) - 120))
UUID_PATTERN='[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}'

mkdir -p "$FAKE_HOME" "$SHIM_BIN" "$START_DIR" "$PROJECT_DIR" "$SIBLING_DIR" "$SPACED_WORKTREE" "$QUOTED_DIR"
PROJECT_PHYSICAL=$(cd "$PROJECT_DIR" && pwd -P)
QUOTED_PHYSICAL=$(cd "$QUOTED_DIR" && pwd -P)

# The shim logs the physical path because macOS temp paths pass through the /var symlink.
cat > "${SHIM_BIN}/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$CALLS"
SHIM
chmod +x "${SHIM_BIN}/claude"

# The supacode shim answers from files in SHIM_DIR that each case sets. A subcommand
# listed in SHIM_DIR/fail exits 1 and prints nothing. `tab new` logs its arguments one
# per line to its own file in SHIM_DIR/tab-new. It appends its epoch second to
# SHIM_DIR/launch-times. It prints a tab ID, as the real command does. After the first
# N launches, where N is in SHIM_DIR/stalled-launches, it writes a sessions file that
# makes the resumed session live, as a claude process that started in the new tab would.
# The shim calls helpers that enter_test_env exports.
cat > "${SHIM_BIN}/supacode" <<'SHIM'
#!/usr/bin/env bash
! grep -qxF -- "$1" "${SHIM_DIR}/fail" 2> /dev/null || exit 1
case "$1:${2-}" in
worktree:list)
	cat "${SHIM_DIR}/worktrees"
	[[ " $* " == *" --not-archived "* ]] || cat "${SHIM_DIR}/archived-worktrees"
	;;
socket:*)
	cat "${SHIM_DIR}/sockets"
	;;
tab:new)
	launch=$(($(find "${SHIM_DIR}/tab-new" -type f | wc -l) + 1))
	printf '%s\n' "$@" > "$(launch_log "$launch")"
	date +%s >> "${SHIM_DIR}/launch-times"
	echo "0F1E2D3C-4B5A-4697-8877-665544332211"
	session_id=$(launched_session "$launch")
	((launch > $(cat "${SHIM_DIR}/stalled-launches"))) && [[ -n "$session_id" ]] &&
		write_session "$LIVE_PID" "$session_id" "$LIVE_START"
	exit 0
	;;
*)
	echo "supacode shim: unexpected arguments: $*" >&2
	exit 64
	;;
esac
SHIM
chmod +x "${SHIM_BIN}/supacode"

cleanup() {
	[[ -z "$LIVE_PID" ]] || kill "$LIVE_PID" 2> /dev/null
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

# A caller runs this in a subshell. It moves the subshell to START_DIR, sets the fake
# home, and puts the shims first on PATH. It exports what the shims read.
enter_test_env() {
	cd "$START_DIR" || exit 1
	export HOME="$FAKE_HOME" PATH="$SHIM_PATH" CALLS SHIM_DIR SESSIONS_DIR UUID_PATTERN LIVE_PID LIVE_START
	export -f launch_log launch_option launched_session write_session
}

# A caller overrides the pane's surface ID, the entrypoint, the Supacode socket, or
# the start timeout for one call with a prefix assignment, such as
# `CASE_SURFACE="" run_restore`. An empty value leaves the variable unset.
# CASE_INTERRUPT_AFTER=<seconds> sends the script SIGINT after that many seconds.
# The start timeout defaults to 5 seconds so that a session that never goes live
# does not hold each case for the script's 60-second default.
run_script() { # subcommand stdin_path [argument...]
	local subcommand="$1" stdin_path="$2" surface="${CASE_SURFACE-$SURFACE}" entrypoint="${CASE_ENTRYPOINT-cli}"
	local socket="${CASE_SOCKET-}" start_timeout="${CASE_START_TIMEOUT-5}"
	shift 2
	: > "$CALLS"
	(
		enter_test_env
		[[ -z "$surface" ]] || export SUPACODE_SURFACE_ID="$surface"
		[[ -z "$entrypoint" ]] || export CLAUDE_CODE_ENTRYPOINT="$entrypoint"
		[[ -z "$socket" ]] || export SUPACODE_SOCKET_PATH="$socket"
		[[ -z "$start_timeout" ]] || export CLAUDE_RESUME_START_TIMEOUT="$start_timeout"
		[[ -z "${CASE_INTERRUPT_AFTER-}" ]] ||
			exec timeout -s INT "$CASE_INTERRUPT_AFTER" "$RESUME" "$subcommand" "$@"
		exec "$RESUME" "$subcommand" "$@"
	) < "$stdin_path" > "$STDOUT_FILE" 2> "$STDERR_FILE"
	STATUS=$?
}

run_hook() { # label input
	printf '%s' "$2" > "$STDIN_FILE"
	run_script hook "$STDIN_FILE"
	check_eq "$1: the hook exits 0" "$STATUS" "0"
	check_eq "$1: the hook prints nothing" "$(cat "$STDOUT_FILE")" ""
}

# Restore waits up to 3 seconds for a keypress.
# EOF on /dev/null ends that wait at once and counts as no keypress.
run_restore() { # [stdin_path]
	CASE_ENTRYPOINT="" run_script restore "${1:-/dev/null}"
}

# restore-all runs from any shell, so it needs no surface ID.
# shellcheck disable=SC2120 # expect_home_unchanged passes --dry-run, and shellcheck does not see it.
run_restore_all() { # [argument...]
	rm -rf "${SHIM_DIR}/tab-new" "${SHIM_DIR}/launch-times"
	mkdir -p "${SHIM_DIR}/tab-new"
	CASE_SURFACE="" CASE_ENTRYPOINT="" run_script restore-all /dev/null "$@"
}

worktree_id() { # path
	jq -rn --arg path "$1/" '$path | @uri'
}

set_worktrees() { # path...
	local path
	for path in "$@"; do
		worktree_id "$path"
	done > "${SHIM_DIR}/worktrees"
}

# Each case starts with one worktree that holds PROJECT_DIR and with two running
# Supacode instances whose sockets no record names.
reset_state() {
	rm -rf "$STATE_DIR" "$SESSIONS_DIR" "$TRANSCRIPT_DIR" "$SHIM_DIR"
	mkdir -p "$TRANSCRIPT_DIR" "$SHIM_DIR"
	printf '%s\n' "$WORKTREE_ID" > "${SHIM_DIR}/worktrees"
	: > "${SHIM_DIR}/archived-worktrees"
	printf '%s\n' "$RUNNING_SOCKET" "$OTHER_RUNNING_SOCKET" > "${SHIM_DIR}/sockets"
	printf '0\n' > "${SHIM_DIR}/stalled-launches"
}

transcript_path() { # session_id
	printf '%s/%s.jsonl\n' "$TRANSCRIPT_DIR" "$1"
}

write_transcript() { # session_id [line...]
	local path
	path=$(transcript_path "$1")
	shift
	{
		printf '%s\n' '{"type":"user","message":{"role":"user","content":"hello"}}'
		[[ $# -eq 0 ]] || printf '%s\n' "$@"
	} > "$path"
}

custom_title() { # title
	jq -n -c --arg title "$1" --arg sid "$SID_A" \
		'{type: "custom-title", customTitle: $title, sessionId: $sid}'
}

ai_title() { # title
	jq -n -c --arg title "$1" '{type: "ai-title", aiTitle: $title}'
}

# ended_at is JSON, so a case can write a string. An empty ended_at or socket
# leaves that field out.
write_record() { # surface session_id cwd transcript_path [ended_at [socket]]
	mkdir -p "$STATE_DIR"
	jq -n -c --arg sid "$2" --arg cwd "$3" --arg transcript "$4" \
		--argjson ended "${5:-null}" --arg socket "${6-}" \
		'{sessionId: $sid, cwd: $cwd, transcriptPath: $transcript}
		+ (if $socket == "" then {} else {supacodeSocket: $socket} end)
		+ (if $ended == null then {} else {endedAt: $ended} end)' > "${STATE_DIR}/$1.json"
}

resumable_record() { # [transcript_line...]
	reset_state
	write_transcript "$SID_A" "$@"
	write_record "$SURFACE" "$SID_A" "$PROJECT_DIR" "$TRANSCRIPT_A"
}

# The record of a session whose SessionEnd ran in a Supacode instance that has quit.
write_ended_record() { # surface session_id ended_at [cwd [socket]]
	write_transcript "$2"
	write_record "$1" "$2" "${4:-$PROJECT_DIR}" "$(transcript_path "$2")" "$3" "${5:-$OLD_SOCKET}"
}

write_session() { # pid session_id proc_start
	mkdir -p "$SESSIONS_DIR"
	jq -n -c --argjson pid "$1" --arg sid "$2" --arg start "$3" \
		'{pid: $pid, sessionId: $sid, procStart: $start, kind: "interactive", entrypoint: "cli"}' \
		> "${SESSIONS_DIR}/$1.json"
}

add_unrelated_sessions() {
	write_session "$$" "$SID_UNRELATED" "$SHELL_START"
	printf 'opaque\n' > "${SESSIONS_DIR}/$$.0123456789abcdef.key"
}

session_start() { # session_id [source]
	jq -n -c --arg sid "$1" --arg source "${2:-startup}" --arg cwd "$PROJECT_DIR" \
		--arg transcript "$(transcript_path "$1")" \
		'{session_id: $sid, transcript_path: $transcript, cwd: $cwd,
		  hook_event_name: "SessionStart", source: $source, model: "claude-opus-5-5[1m]"}'
}

session_end() { # session_id reason
	jq -n -c --arg sid "$1" --arg reason "$2" --arg cwd "$PROJECT_DIR" \
		--arg transcript "$(transcript_path "$1")" \
		'{session_id: $sid, transcript_path: $transcript, cwd: $cwd,
		  hook_event_name: "SessionEnd", reason: $reason}'
}

record_field() { # path jq_expression
	jq -r "$2" "$1" 2> /dev/null
}

home_snapshot() {
	find "$FAKE_HOME" -type f -exec cksum {} + | sort
}

expect_home_unchanged() { # label command...
	local label="$1" before
	shift
	before=$(home_snapshot)
	"$@"
	check_eq "$label: nothing in the home changes" "$(home_snapshot)" "$before"
}

call_count() {
	wc -l < "$CALLS" | tr -d ' '
}

output() {
	cat "$STDOUT_FILE" "$STDERR_FILE"
}

lines_with() { # text
	output | grep -cF -- "$1"
}

has_line_with() { # text...
	local line text
	while IFS= read -r line; do
		for text in "$@"; do
			[[ "$line" == *"$text"* ]] || continue 2
		done
		return 0
	done < <(output)
	return 1
}

is_between() { # value low high
	[[ "$1" =~ ^[0-9]+$ ]] && (($2 <= $1 && $1 <= $3))
}

sorted() { # value...
	printf '%s\n' "$@" | sort
}

tab_new_count() {
	find "${SHIM_DIR}/tab-new" -type f | wc -l | tr -d ' '
}

seconds_between_first_launches() {
	awk 'NR == 1 { first = $1 } NR == 2 { print $1 - first }' "${SHIM_DIR}/launch-times" 2> /dev/null
}

launch_log() { # launch_number
	printf '%s/tab-new/%s\n' "$SHIM_DIR" "$1"
}

launch_has() { # launch_number argument
	grep -qxF -- "$2" "$(launch_log "$1")" 2> /dev/null
}

launch_option() { # launch_number short_option long_option
	awk -v short="$2" -v long="$3" 'found { print; exit } $0 == short || $0 == long { found = 1 }' \
		"$(launch_log "$1")" 2> /dev/null
}

launched_session() { # launch_number
	launch_option "$1" -i --input | grep -oE "$UUID_PATTERN" | head -n 1
}

launched_sessions() {
	local launch
	for ((launch = 1; launch <= $(tab_new_count); launch++)); do
		launched_session "$launch"
	done | sort
}

# Runs a tab's -i command the way the tab's shell would, from a directory that is
# not the session's cwd.
run_launch_input() { # launch_number
	local input
	input=$(launch_option "$1" -i --input)
	: > "$CALLS"
	(enter_test_env && bash -c "$input")
}

# BSD ps pads lstart with trailing spaces. Procps does not.
proc_start() { # pid
	TZ=UTC ps -o lstart= -p "$1" | sed 's/[[:space:]]*$//'
}

if [[ ! -x "$RESUME" ]]; then
	fail "ai/bin/supacode-claude-resume.sh exists and is executable"
	reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
printf 'tab\n' > "${SHIM_DIR}/fail"
run_restore_all
check_eq "a failing supacode tab new does not fail restore-all" "$STATUS" "0"
check "restore-all names a session whose tab did not open" has_line_with "could not open" "$SID_A"
check_eq "restore-all does not wait for a session whose tab did not open" "$(lines_with "did not start")" "0"

# ── Restore-all: arguments ───────────────────────────────────────────────────

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
expect_home_unchanged "an unknown restore-all option" run_restore_all --dryrun
check_eq "an unknown restore-all option exits 2" "$STATUS" "2"
check_eq "an unknown restore-all option opens no tab" "$(tab_new_count)" "0"

printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
	exit 1
fi

# Without the redirect, the live process holds the suite's output pipe open until it exits.
sleep 300 > /dev/null 2>&1 &
LIVE_PID=$!
LIVE_START=$(proc_start "$LIVE_PID")
SHELL_START=$(proc_start "$$")
WORKTREE_ID=$(worktree_id "$WORKTREE_DIR")

# A reaped child's pid names a process that is no longer running.
: &
DEAD_PID=$!
wait "$DEAD_PID"

check "the live process has a start time" test -n "$LIVE_START"

# ── Hook: SessionStart records the pane's session ───────────────────────────

reset_state
run_hook "a SessionStart" "$(session_start "$SID_A")"
check_eq "it writes only the pane's record" "$(find "$STATE_DIR" -type f 2> /dev/null)" "$RECORD"
check_eq "sessionId is the input's session_id" "$(record_field "$RECORD" .sessionId)" "$SID_A"
check_eq "cwd is the input's cwd" "$(record_field "$RECORD" .cwd)" "$PROJECT_DIR"
check_eq "transcriptPath is the input's transcript_path" "$(record_field "$RECORD" .transcriptPath)" "$TRANSCRIPT_A"
check_eq "with no SUPACODE_SOCKET_PATH supacodeSocket is an empty string" \
	"$(record_field "$RECORD" '.supacodeSocket | tojson')" '""'

reset_state
CASE_SOCKET="$OLD_SOCKET" run_hook "a SessionStart with a Supacode socket" "$(session_start "$SID_A")"
check_eq "supacodeSocket is SUPACODE_SOCKET_PATH" "$(record_field "$RECORD" .supacodeSocket)" "$OLD_SOCKET"

reset_state
CASE_SURFACE="$LOWER_SURFACE" run_hook "a lowercase surface ID" "$(session_start "$SID_A")"
check "a lowercase surface ID gets a record" test -f "${STATE_DIR}/${LOWER_SURFACE}.json"

resumable_record
run_hook "a SessionStart after /clear" "$(session_start "$SID_B" clear)"
check_eq "the new session replaces the old one in the record" \
	"$(record_field "$RECORD" .sessionId)" "$SID_B"

expect_session_id_rejected() { # label session_id
	local before
	resumable_record
	before=$(cat "$RECORD")
	run_hook "$1" "$(session_start "$2")"
	check_eq "$1: the record is unchanged" "$(cat "$RECORD")" "$before"
}

expect_session_id_rejected "an empty session_id" ""
expect_session_id_rejected "a session_id that is not a UUID" "abc"
expect_session_id_rejected "a UUID session_id with a flag after it" \
	"${SID_B} --dangerously-skip-permissions"

# ── Hook: who gets a record ──────────────────────────────────────────────────
# Each case seeds the pane's record, which a valid SessionStart for SID_B would
# overwrite. It also seeds another pane's record of SID_B, which that SessionStart
# would delete. An unchanged home shows the hook did neither.

expect_hook_ignored() { # label surface entrypoint
	resumable_record
	write_record "$OTHER_SURFACE" "$SID_B" "$PROJECT_DIR" "$(transcript_path "$SID_B")"
	CASE_SURFACE="$2" CASE_ENTRYPOINT="$3" expect_home_unchanged "$1" run_hook "$1" "$(session_start "$SID_B")"
}

expect_hook_ignored "claude -p (entrypoint sdk-cli)" "$SURFACE" sdk-cli
expect_hook_ignored "an unset CLAUDE_CODE_ENTRYPOINT" "$SURFACE" ""
expect_hook_ignored "an unset SUPACODE_SURFACE_ID" "" cli
expect_hook_ignored "a surface ID that climbs out of the state dir" "../evil" cli
expect_hook_ignored "a UUID surface ID behind a path prefix" "../${OTHER_SURFACE}" cli

reset_state
run_hook "stdin that is not JSON" "not json"
check "stdin that is not JSON writes no record" test ! -e "$RECORD"

reset_state
run_hook "empty stdin" ""
check "empty stdin writes no record" test ! -e "$RECORD"

# ── Hook: a session belongs to one pane ─────────────────────────────────────

reset_state
write_record "$OTHER_SURFACE" "$SID_A" "$PROJECT_DIR" "$TRANSCRIPT_A"
write_record "$LOWER_SURFACE" "$SID_UNRELATED" "$PROJECT_DIR" "$(transcript_path "$SID_UNRELATED")"
run_hook "a resume in another pane" "$(session_start "$SID_A" resume)"
check_eq "the pane that resumed the session records it" "$(record_field "$RECORD" .sessionId)" "$SID_A"
check "another pane's record of the same session is deleted" test ! -e "${STATE_DIR}/${OTHER_SURFACE}.json"
check "another pane's record of a different session is kept" test -f "${STATE_DIR}/${LOWER_SURFACE}.json"

# ── Hook: SessionEnd ─────────────────────────────────────────────────────────

run_session_end() { # label session_id reason
	resumable_record
	run_hook "$1" "$(session_end "$2" "$3")"
}

run_session_end "an exit at the prompt" "$SID_A" prompt_input_exit
check "an exit at the prompt deletes the record" test ! -e "$RECORD"

run_session_end "an exit at the prompt from another session" "$SID_B" prompt_input_exit
check "an exit at the prompt from another session keeps the record" test -f "$RECORD"

reset_state
run_hook "a SessionEnd with no record" "$(session_end "$SID_A" prompt_input_exit)"
check "a SessionEnd with no record creates none" test ! -e "$RECORD"

# ── Hook: SessionEnd marks the record ended ─────────────────────────────────
# restore-all resumes only records that a SessionEnd marked with endedAt.

expect_record_marked_ended() { # label reason
	local before low high
	reset_state
	write_transcript "$SID_A"
	write_record "$SURFACE" "$SID_A" "$PROJECT_DIR" "$TRANSCRIPT_A" "" "$OLD_SOCKET"
	before=$(jq -S -c . "$RECORD")
	low=$(date +%s)
	run_hook "$1" "$(session_end "$SID_A" "$2")"
	high=$(date +%s)
	check_eq "$1: endedAt is a JSON number" "$(record_field "$RECORD" '.endedAt | type')" "number"
	check "$1: endedAt is the epoch second of the SessionEnd" \
		is_between "$(record_field "$RECORD" .endedAt)" "$low" "$high"
	check_eq "$1: the record keeps its other fields" "$(jq -S -c 'del(.endedAt)' "$RECORD" 2> /dev/null)" "$before"
	check_eq "$1: the state dir holds only the record" "$(find "$STATE_DIR" -type f)" "$RECORD"
}

expect_record_marked_ended "a SessionEnd with reason other" other
expect_record_marked_ended "a SessionEnd with reason clear" clear

expect_session_end_ignored() { # label session_id
	expect_home_unchanged "$1" run_hook "$1" "$(session_end "$2" other)"
}

resumable_record
expect_session_end_ignored "a SessionEnd with reason other from another session" "$SID_B"

reset_state
write_record "$OTHER_SURFACE" "$SID_A" "$PROJECT_DIR" "$TRANSCRIPT_A"
expect_session_end_ignored "a SessionEnd with reason other and no record for the pane" "$SID_A"

# ── Restore: resuming ────────────────────────────────────────────────────────

resumable_record
run_restore
check_eq "restore runs claude once" "$(call_count)" "1"
check_eq "it passes only --resume and the session ID" "$(cut -d'|' -f2- "$CALLS")" "--resume ${SID_A}"
check_eq "it runs claude in the recorded cwd" "$(cut -d'|' -f1 "$CALLS")" "$PROJECT_PHYSICAL"
check "without a title restore prints the session ID" grep -qF -- "$SID_A" "$STDOUT_FILE"

resumable_record
CASE_SURFACE="" run_restore
check_eq "with no SUPACODE_SURFACE_ID restore exits 0" "$STATUS" "0"
check_eq "with no SUPACODE_SURFACE_ID claude does not run" "$(call_count)" "0"

# Without the UUID check this path would resolve to the pane's real record.
resumable_record
CASE_SURFACE="../claude-resume/${SURFACE}" run_restore
check_eq "a surface ID that is a path does not reach claude" "$(call_count)" "0"

reset_state
write_transcript "$SID_A"
write_record "$OTHER_SURFACE" "$SID_A" "$PROJECT_DIR" "$TRANSCRIPT_A"
run_restore
check_eq "with no record for the pane restore exits 0" "$STATUS" "0"
check_eq "with no record for the pane claude does not run" "$(call_count)" "0"

resumable_record "$(custom_title my-title)"
run_restore
check "restore prints the session's custom title" grep -qF -- my-title "$STDOUT_FILE"

resumable_record "$(ai_title "AI Title")"
run_restore
check "without a custom title restore prints the AI title" grep -qF -- "AI Title" "$STDOUT_FILE"

resumable_record "$(custom_title first-title)" "$(custom_title renamed-title)"
run_restore
check "the last custom title is printed" grep -qF -- renamed-title "$STDOUT_FILE"
check_eq "an earlier custom title is not printed" "$(grep -cF -- first-title "$STDOUT_FILE")" "0"

resumable_record "$(custom_title my-title)" "$(ai_title "AI Title")"
run_restore
check "a custom title wins over an AI title" grep -qF -- my-title "$STDOUT_FILE"
check_eq "the AI title is not printed next to a custom title" "$(grep -cF -- "AI Title" "$STDOUT_FILE")" "0"

resumable_record
printf x > "$KEYPRESS_FILE"
run_restore "$KEYPRESS_FILE"
check_eq "a keypress cancels the resume" "$(call_count)" "0"
check "a cancelled resume deletes the record" test ! -e "$RECORD"

# A FIFO opened read-write never delivers a key. The countdown waits until
# timeout sends SIGINT, which is what Ctrl-C sends.
if command -v timeout > /dev/null 2>&1; then
	resumable_record
	mkfifo "$IDLE_FIFO"
	exec 3<> "$IDLE_FIFO"
	CASE_INTERRUPT_AFTER=1 run_restore /dev/fd/3
	exec 3>&-
	check_eq "Ctrl-C cancels the resume" "$(call_count)" "0"
	check "Ctrl-C at the countdown deletes the record" test ! -e "$RECORD"
else
	printf 'SKIP: Ctrl-C at the countdown, because timeout is not installed\n' >&2
fi

# ── Restore and restore-all: records they cannot trust ───────────────────────

expect_record_discarded() { # label session_id cwd transcript_path
	reset_state
	write_transcript "$SID_A"
	write_record "$SURFACE" "$2" "$3" "$4"
	run_restore
	check_eq "$1: claude does not run" "$(call_count)" "0"
	check "$1: restore deletes the record" test ! -e "$RECORD"

	write_record "$SURFACE" "$2" "$3" "$4" "$ENDED_AT" "$OLD_SOCKET"
	expect_home_unchanged "$1 with --dry-run" run_restore_all --dry-run
	run_restore_all
	check_eq "$1: restore-all opens no tab" "$(tab_new_count)" "0"
	check "$1: restore-all deletes the ended record" test ! -e "$RECORD"
}

expect_record_discarded "an empty sessionId" "" "$PROJECT_DIR" "$TRANSCRIPT_A"
expect_record_discarded "a sessionId that is not a UUID" not-a-uuid "$PROJECT_DIR" "$TRANSCRIPT_A"
expect_record_discarded "a UUID sessionId with a flag after it" \
	"${SID_A} --dangerously-skip-permissions" "$PROJECT_DIR" "$TRANSCRIPT_A"
expect_record_discarded "a cwd that no longer exists" "$SID_A" "${TEST_ROOT}/gone" "$TRANSCRIPT_A"
expect_record_discarded "a transcript that no longer exists" \
	"$SID_A" "$PROJECT_DIR" "${TRANSCRIPT_DIR}/gone.jsonl"

reset_state
mkdir -p "$STATE_DIR"
printf 'not json\n' > "$RECORD"
run_restore
check_eq "a record that is not JSON never reaches claude" "$(call_count)" "0"

# ── Restore: a session that is still running ────────────────────────────────
# Claude Code writes sessions/<pid>.json for each running session.
# procStart distinguishes a live session from a recycled pid.

run_with_session_file() { # session_id pid proc_start
	resumable_record
	add_unrelated_sessions
	write_session "$2" "$1" "$3"
	run_restore
}

run_with_session_file "$SID_A" "$LIVE_PID" "$LIVE_START"
check_eq "a session that is still running is not resumed again" "$(call_count)" "0"
check "a session that is still running keeps its record" test -f "$RECORD"

run_with_session_file "$SID_A" "$LIVE_PID" "Thu Jan  1 00:00:00 1970"
check_eq "a sessions file whose procStart does not match its pid does not block the resume" \
	"$(call_count)" "1"

run_with_session_file "$SID_A" "$DEAD_PID" "$LIVE_START"
check_eq "a sessions file for a dead pid does not block the resume" "$(call_count)" "1"

run_with_session_file "$SID_B" "$LIVE_PID" "$LIVE_START"
check_eq "a running session with another sessionId does not block the resume" "$(call_count)" "1"

# ── Restore-all: launching a session ─────────────────────────────────────────
# This case leaves CLAUDE_RESUME_START_TIMEOUT unset, so the script uses its default.

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
CASE_START_TIMEOUT="" run_restore_all
check_eq "restore-all exits 0" "$STATUS" "0"
check_eq "restore-all opens one tab" "$(tab_new_count)" "1"
check_eq "the tab resumes the recorded session" "$(launched_sessions)" "$SID_A"
check_eq "the tab opens in the worktree that holds the cwd" "$(launch_option 1 -w --worktree)" "$WORKTREE_ID"
check "the tab opens in the background" launch_has 1 --background
check_eq "restore-all does not run claude itself" "$(call_count)" "0"
check "restore-all keeps the record after it opens the tab" test -f "$RECORD"
run_launch_input 1
check_eq "the tab's command runs claude in the recorded cwd" "$(cut -d'|' -f1 "$CALLS")" "$PROJECT_PHYSICAL"
check_eq "the tab's command passes only --resume and the session ID" \
	"$(cut -d'|' -f2- "$CALLS")" "--resume ${SID_A}"

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT" "$QUOTED_DIR"
run_restore_all
run_launch_input 1
check_eq "a cwd with a space and a quote reaches the tab's shell intact" \
	"$(cut -d'|' -f1 "$CALLS")" "$QUOTED_PHYSICAL"
check_eq "a cwd with a space and a quote leaves the claude arguments intact" \
	"$(cut -d'|' -f2- "$CALLS")" "--resume ${SID_A}"

# The restore cases cover which title session_title picks.
reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_transcript "$SID_A" "$(custom_title my-title)"
expect_home_unchanged "--dry-run" run_restore_all --dry-run
check_eq "--dry-run exits 0" "$STATUS" "0"
check "--dry-run prints the session's title and cwd" has_line_with my-title "$PROJECT_DIR"
check_eq "--dry-run opens no tab" "$(tab_new_count)" "0"
run_restore_all
check "restore-all prints the session's title and cwd" has_line_with my-title "$PROJECT_DIR"

reset_state
run_restore_all
check_eq "with no records restore-all exits 0" "$STATUS" "0"
check "with no records restore-all prints a message" test -n "$(output)"

resumable_record
run_restore_all
check_eq "with only records that never ended restore-all exits 0" "$STATUS" "0"
check "with only records that never ended restore-all prints a message" test -n "$(output)"
check_eq "a record that never ended is not resumed" "$(tab_new_count)" "0"
check "restore-all keeps a record that never ended" test -f "$RECORD"

# ── Restore-all: which records it resumes ────────────────────────────────────

reset_state
write_transcript "$SID_A"
write_record "$SURFACE" "$SID_A" "${TEST_ROOT}/gone" "$TRANSCRIPT_A"
run_restore_all
check "restore-all keeps a record that never ended even when its cwd is gone" test -f "$RECORD"

reset_state
write_ended_record "$SURFACE" "$SID_A" '"yesterday"'
run_restore_all
check_eq "a record whose endedAt is not a number is not resumed" "$(tab_new_count)" "0"

# A session from the running Supacode ended because its tab closed.
reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT" "$PROJECT_DIR" "$OTHER_RUNNING_SOCKET"
run_restore_all
check_eq "a session that ended in a running Supacode is not resumed" "$(tab_new_count)" "0"
check "restore-all deletes the record of a session that ended in a running Supacode" test ! -f "$RECORD"

# A record written before the hook recorded sockets gains endedAt at the next quit
# but no supacodeSocket. The running Supacode's socket must not match it.
expect_record_without_socket_resumed() { # label jq_filter
	local record
	reset_state
	write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
	record=$(jq -c "$2" "$RECORD") && printf '%s\n' "$record" > "$RECORD"
	run_restore_all
	check_eq "$1 is resumed" "$(launched_sessions)" "$SID_A"
}

expect_record_without_socket_resumed "an ended record with no supacodeSocket field" 'del(.supacodeSocket)'
expect_record_without_socket_resumed "an ended record with an empty supacodeSocket" '.supacodeSocket = ""'

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_session "$LIVE_PID" "$SID_A" "$LIVE_START"
run_restore_all
check_eq "restore-all does not resume a session that is still running" "$(tab_new_count)" "0"
check "restore-all keeps the record of a session that is still running" test -f "$RECORD"

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_ended_record "$OTHER_SURFACE" "$SID_A" "$ENDED_AT"
run_restore_all
check_eq "a session recorded by two panes gets one tab" "$(tab_new_count)" "1"

reset_state
write_ended_record "$OTHER_SURFACE" "$SID_A" "$ENDED_AT"
printf 'not json\n' > "$RECORD"
run_restore_all
check_eq "a record that is not JSON does not stop restore-all" "$(launched_sessions)" "$SID_A"
check "restore-all keeps a record that is not JSON" test -f "$RECORD"

# ── Restore-all: sessions that stopped together ──────────────────────────────
# A Supacode quit ends all of its sessions within a few seconds.

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_ended_record "$OTHER_SURFACE" "$SID_B" "$((ENDED_AT - 60))"
write_ended_record "$LOWER_SURFACE" "$SID_C" "$((ENDED_AT - 61))"
run_restore_all
check_eq "restore-all resumes the sessions that ended within 60 seconds of the newest" \
	"$(launched_sessions)" "$(sorted "$SID_A" "$SID_B")"
check "restore-all deletes the record of a session that ended 61 seconds before the newest" test ! -f "$LOWER_RECORD"

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_ended_record "$OTHER_SURFACE" "$SID_B" "$((ENDED_AT + 300))" "$PROJECT_DIR" "$RUNNING_SOCKET"
run_restore_all
check_eq "a newer record that restore-all cannot resume does not move the group" \
	"$(launched_sessions)" "$SID_A"

# ── Restore-all: the worktree of a cwd ───────────────────────────────────────

# The shorter worktree path is listed first, so the first match is the wrong one.
reset_state
set_worktrees "$TEST_ROOT" "$WORKTREE_DIR"
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
run_restore_all
check_eq "a cwd maps to the longest worktree path that holds it" "$(launch_option 1 -w --worktree)" "$WORKTREE_ID"

reset_state
set_worktrees "$SPACED_WORKTREE"
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT" "$SPACED_WORKTREE"
run_restore_all
check_eq "a cwd that is a worktree's own path gets the worktree ID as listed" \
	"$(launch_option 1 -w --worktree)" "$(worktree_id "$SPACED_WORKTREE")"

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT" "$SIBLING_DIR"
write_ended_record "$OTHER_SURFACE" "$SID_B" "$ENDED_AT"
run_restore_all
check_eq "a cwd beside a worktree's path is not in that worktree" "$(launched_sessions)" "$SID_B"
check "restore-all names a cwd that is in no worktree" has_line_with "$SIBLING_DIR"
check "restore-all keeps the record of a cwd that is in no worktree" test -f "$RECORD"
check_eq "a cwd in no worktree does not fail restore-all" "$STATUS" "0"

reset_state
mv "${SHIM_DIR}/worktrees" "${SHIM_DIR}/archived-worktrees"
: > "${SHIM_DIR}/worktrees"
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
run_restore_all
check_eq "a cwd in an archived worktree is not resumed" "$(tab_new_count)" "0"

# ── Restore-all: a session that does not start ───────────────────────────────
# The shim's first tab never starts its session. The session's own line names it
# once, and the message after the wait gives up names it again.

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_ended_record "$OTHER_SURFACE" "$SID_B" "$ENDED_AT"
printf '1\n' > "${SHIM_DIR}/stalled-launches"
CASE_START_TIMEOUT=1 run_restore_all
check_eq "the session after one that does not start still gets a tab" \
	"$(launched_sessions)" "$(sorted "$SID_A" "$SID_B")"
check "restore-all waits CLAUDE_RESUME_START_TIMEOUT seconds before it opens the next tab" \
	is_between "$(seconds_between_first_launches)" 1 10
check "restore-all names a session that does not start" test "$(lines_with "$(launched_session 1)")" -ge 2

# ── Restore-all: records a run skips ─────────────────────────────────────────
# A session's SessionStart deletes its old record, so a skipped record that stays
# on disk later looks like the newest quit.

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_ended_record "$OTHER_SURFACE" "$SID_B" "$((ENDED_AT - 3600))"
run_restore_all
check_eq "restore-all skips a record from before the quit window" "$(launched_sessions)" "$SID_A"
rm -f "$RECORD"
run_restore_all
check_eq "a second restore-all opens no tab" "$(tab_new_count)" "0"
check "restore-all deletes a record from before the quit window" test ! -f "${STATE_DIR}/${OTHER_SURFACE}.json"

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
write_ended_record "$OTHER_SURFACE" "$SID_B" "$((ENDED_AT - 3600))"
run_restore_all --dry-run
check "a dry run keeps a record from before the quit window" test -f "${STATE_DIR}/${OTHER_SURFACE}.json"

# ── Restore-all: when supacode fails ─────────────────────────────────────────
# The shim fails without output, so any error text comes from restore-all.

expect_supacode_failure() { # label subcommand
	reset_state
	write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
	printf '%s\n' "$2" > "${SHIM_DIR}/fail"
	run_restore_all
	check "$1: restore-all exits nonzero" test "$STATUS" -ne 0
	check "$1: restore-all prints an error to stderr" test -s "$STDERR_FILE"
	check_eq "$1: restore-all opens no tab" "$(tab_new_count)" "0"
}

expect_supacode_failure "a failing supacode worktree list" worktree
expect_supacode_failure "a failing supacode socket" socket

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
printf 'tab\n' > "${SHIM_DIR}/fail"
run_restore_all
check_eq "a failing supacode tab new does not fail restore-all" "$STATUS" "0"
check "restore-all names a session whose tab did not open" has_line_with "could not open" "$SID_A"
check_eq "restore-all does not wait for a session whose tab did not open" "$(lines_with "did not start")" "0"

# ── Restore-all: arguments ───────────────────────────────────────────────────

reset_state
write_ended_record "$SURFACE" "$SID_A" "$ENDED_AT"
expect_home_unchanged "an unknown restore-all option" run_restore_all --dryrun
check_eq "an unknown restore-all option exits 2" "$STATUS" "2"
check_eq "an unknown restore-all option opens no tab" "$(tab_new_count)" "0"

printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
[[ "${failures}" -eq 0 ]]
