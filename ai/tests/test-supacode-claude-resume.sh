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
START_DIR="${TEST_ROOT}/start"
PROJECT_DIR="${TEST_ROOT}/project/sub"
CALLS="${TEST_ROOT}/claude-calls"
STDIN_FILE="${TEST_ROOT}/stdin"
KEYPRESS_FILE="${TEST_ROOT}/keypress"
IDLE_FIFO="${TEST_ROOT}/idle"
STDOUT_FILE="${TEST_ROOT}/stdout"
STATUS=0
LIVE_PID=""

SURFACE="8DA2BAC1-73BB-4F5D-B8B5-F458AD9FFB8E"
OTHER_SURFACE="5E7D9C3A-2B4F-4A61-9D8E-7C6B5A4F3E2D"
LOWER_SURFACE="c4f1e2d3-a5b6-4c7d-8e9f-0a1b2c3d4e5f"
SID_A="702bd8a4-524b-40cc-b3b7-b6b99f83e45f"
SID_B="3f6c2b1e-9a4d-4e8b-8c7f-1d2e3f4a5b6c"
SID_UNRELATED="9b8a7c6d-5e4f-4a3b-8c2d-1e0f9a8b7c6d"
RECORD="${STATE_DIR}/${SURFACE}.json"
TRANSCRIPT_A="${TRANSCRIPT_DIR}/${SID_A}.jsonl"

mkdir -p "$FAKE_HOME" "$SHIM_BIN" "$START_DIR" "$PROJECT_DIR"
PROJECT_PHYSICAL=$(cd "$PROJECT_DIR" && pwd -P)

# The shim logs the physical path because macOS temp paths pass through the /var symlink.
cat > "${SHIM_BIN}/claude" <<'SHIM'
#!/usr/bin/env bash
printf '%s|%s\n' "$(pwd -P)" "$*" >> "$CALLS"
SHIM
chmod +x "${SHIM_BIN}/claude"

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

# A caller overrides the pane's surface ID or the entrypoint for one call with a
# prefix assignment, such as `CASE_SURFACE="" run_restore`. An empty value
# leaves the variable unset. CASE_INTERRUPT_AFTER=<seconds> sends the script
# SIGINT after that many seconds.
run_script() { # subcommand stdin_path
	local surface="${CASE_SURFACE-$SURFACE}" entrypoint="${CASE_ENTRYPOINT-cli}"
	: > "$CALLS"
	(
		cd "$START_DIR" || exit 1
		export HOME="$FAKE_HOME" PATH="${SHIM_BIN}:${PATH}" CALLS
		[[ -z "$surface" ]] || export SUPACODE_SURFACE_ID="$surface"
		[[ -z "$entrypoint" ]] || export CLAUDE_CODE_ENTRYPOINT="$entrypoint"
		[[ -z "${CASE_INTERRUPT_AFTER-}" ]] || exec timeout -s INT "$CASE_INTERRUPT_AFTER" "$RESUME" "$1"
		exec "$RESUME" "$1"
	) < "$2" > "$STDOUT_FILE"
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

reset_state() {
	rm -rf "$STATE_DIR" "$SESSIONS_DIR" "$TRANSCRIPT_DIR"
	mkdir -p "$TRANSCRIPT_DIR"
}

transcript_path() { # session_id
	printf '%s/%s.jsonl\n' "$TRANSCRIPT_DIR" "$1"
}

write_transcript() { # session_id [line...]
	local path
	path=$(transcript_path "$1")
	shift
	{
		jq -n -c '{type: "user", message: {role: "user", content: "hello"}}'
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

write_record() { # surface session_id cwd transcript_path
	mkdir -p "$STATE_DIR"
	jq -n -c --arg sid "$2" --arg cwd "$3" --arg transcript "$4" \
		'{sessionId: $sid, cwd: $cwd, transcriptPath: $transcript}' > "${STATE_DIR}/$1.json"
}

resumable_record() { # [transcript_line...]
	reset_state
	write_transcript "$SID_A" "$@"
	write_record "$SURFACE" "$SID_A" "$PROJECT_DIR" "$TRANSCRIPT_A"
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

call_count() {
	wc -l < "$CALLS" | tr -d ' '
}

# BSD ps pads lstart with trailing spaces. Procps does not.
proc_start() { # pid
	TZ=UTC ps -o lstart= -p "$1" | sed 's/[[:space:]]*$//'
}

if [[ ! -x "$RESUME" ]]; then
	fail "ai/bin/supacode-claude-resume.sh exists and is executable"
	printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
	exit 1
fi

# Without the redirect, the live process holds the suite's output pipe open until it exits.
sleep 300 > /dev/null 2>&1 &
LIVE_PID=$!
LIVE_START=$(proc_start "$LIVE_PID")
SHELL_START=$(proc_start "$$")

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
	local before
	resumable_record
	write_record "$OTHER_SURFACE" "$SID_B" "$PROJECT_DIR" "$(transcript_path "$SID_B")"
	before=$(home_snapshot)
	CASE_SURFACE="$2" CASE_ENTRYPOINT="$3" run_hook "$1" "$(session_start "$SID_B")"
	check_eq "$1: nothing in the home changes" "$(home_snapshot)" "$before"
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

run_session_end "a SessionEnd with reason other" "$SID_A" other
check "a SessionEnd with reason other keeps the record" test -f "$RECORD"

run_session_end "a SessionEnd with reason clear" "$SID_A" clear
check "a SessionEnd with reason clear keeps the record" test -f "$RECORD"

run_session_end "an exit at the prompt from another session" "$SID_B" prompt_input_exit
check "an exit at the prompt from another session keeps the record" test -f "$RECORD"

reset_state
run_hook "a SessionEnd with no record" "$(session_end "$SID_A" prompt_input_exit)"
check "a SessionEnd with no record creates none" test ! -e "$RECORD"

# ── Restore: resuming ────────────────────────────────────────────────────────

resumable_record
run_restore
check_eq "restore runs claude once" "$(call_count)" "1"
check_eq "it passes only --resume and the session ID" "$(cut -d'|' -f2- "$CALLS")" "--resume ${SID_A}"
check_eq "it runs claude in the recorded cwd" "$(cut -d'|' -f1 "$CALLS")" "$PROJECT_PHYSICAL"

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

# ── Restore: records it cannot trust ─────────────────────────────────────────

expect_record_discarded() { # label session_id cwd transcript_path
	reset_state
	write_transcript "$SID_A"
	write_record "$SURFACE" "$2" "$3" "$4"
	run_restore
	check_eq "$1: claude does not run" "$(call_count)" "0"
	check "$1: restore deletes the record" test ! -e "$RECORD"
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

printf 'Passed: %d, Failed: %d\n' "$passes" "$failures"
[[ "${failures}" -eq 0 ]]
