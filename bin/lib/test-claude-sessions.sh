#!/bin/bash
# Tests for claude-sessions: the live Claude Code sessions, what each one waits
# on, its git and PR state, and the tail of its transcript.
#
# Usage: test-claude-sessions.sh
#
# Every session comes from a fixture, so every case is offline:
# - A `claude` shim on PATH prints $AGENTS for `claude agents --json`.
# - CLAUDE_CONFIG_DIR holds the sessions/<pid>.json files and the transcripts.
# - A `gh` shim answers `gh pr list` from the PRs in $PRS. The real git-pr from
#   this checkout runs against it.
# The controlled PATH keeps system git visible and the real gh and claude
# invisible. The shims append one line per call to $CALLS.
#
# The pid of each session that add_interactive adds belongs to a `sleep` that
# this suite starts, so a check that the pid is alive passes. The sleeps have no
# terminal. dead_pid gives the pid of a process that has exited.
#
# --json prints one JSON array, sorted. Each object's keys are the table's
# columns in lowercase, plus cwd, pid, sessionId, transcript, and tail
# ({user, assistant}). An empty column is null.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

BIN="$SCRIPT_DIR/../claude-sessions"
REPO_BIN="$(cd "$SCRIPT_DIR/.." && pwd)"

if [ ! -x "$BIN" ]; then
    assert "bin/claude-sessions exists and is executable" false
    print_results
    exit
fi

# The developer's own Claude Code and Supacode variables would otherwise reach
# the script.
unset "${!CLAUDE@}" "${!SUPACODE_@}"

# ── Fixture ──────────────────────────────────────────────────────────────────

TESTTMP="$(cd "$(mktemp -d)" && pwd -P)"
SLEEPERS=()
stop_sleepers() {
    [ ${#SLEEPERS[@]} -eq 0 ] || kill "${SLEEPERS[@]}" 2>/dev/null
    SLEEPERS=()
}
trap 'stop_sleepers; rm -rf "$TESTTMP"' EXIT

CONFIG="$TESTTMP/claude"
FAKE_HOME="$TESTTMP/home"
PROJECTS="$CONFIG/projects/-fixture"
AGENTS="$TESTTMP/agents.json"
PRS="$TESTTMP/prs.json"
CALLS="$TESTTMP/calls"
PLAIN="$TESTTMP/plain"

NOW=$(date +%s)

mkdir -p "$FAKE_HOME" "$PLAIN" "$TESTTMP/bin"

export GIT_CONFIG_GLOBAL="$TESTTMP/gitconfig" GIT_CONFIG_NOSYSTEM=1
: > "$GIT_CONFIG_GLOBAL"

# claude-sessions and git-pr run under the first bash on PATH. git-pr needs
# bash 4, which macOS's /bin/bash is not.
find_bash4
ln -s "$BASH4" "$TESTTMP/bin/bash"
SHIM_PATH="$TESTTMP/bin:$REPO_BIN:/usr/bin:/bin"

cat > "$TESTTMP/bin/claude" <<'SHIM'
#!/bin/bash
echo "claude $*" >> "$CALLS"
if [ "${1-}" = agents ] && [[ " $* " == *" --json "* ]]; then
    cat "$AGENTS"
    exit 0
fi
echo "claude shim: unexpected call: $*" >&2
exit 1
SHIM

cat > "$TESTTMP/bin/gh" <<'SHIM'
#!/bin/bash
# Answers `gh pr list` from the PR objects in $PRS, filtered on --head and
# --state. -q or --jq applies to the answer as gh applies it.
echo "gh $*" >> "$CALLS"
if [ "${1-} ${2-}" != "pr list" ]; then
    echo "gh shim: unexpected call: $*" >&2
    exit 1
fi
prev= head= state= q=.
for arg; do
    case $prev in
        --head) head=$arg ;;
        --state) state=$arg ;;
        -q | --jq) q=$arg ;;
    esac
    prev=$arg
done
jq -c --arg head "$head" --arg state "${state:-open}" '
    map(select(($head == "" or .headRefName == $head)
        and ($state == "all" or .state == ($state | ascii_upcase))))' "$PRS" |
    jq -r "$q"
SHIM
chmod +x "$TESTTMP/bin/claude" "$TESTTMP/bin/gh"

# Removes every session, transcript, and PR. Stops the sleeps that stood for the
# earlier sessions.
reset_fixture() {
    stop_sleepers
    rm -rf "$CONFIG"
    mkdir -p "$CONFIG/sessions" "$PROJECTS"
    echo '[]' > "$AGENTS"
    echo '[]' > "$PRS"
}

# A session ID in UUID form, derived from the session's name.
sid_of() { # sid_of <name>
    local h
    h=$(printf '%s' "$1" | shasum | cut -c1-32)
    printf '%s-%s-4%s-8%s-%s\n' "${h:0:8}" "${h:8:4}" "${h:13:3}" "${h:17:3}" "${h:20:12}"
}

transcript_of() { # transcript_of <name>
    printf '%s/%s.jsonl\n' "$PROJECTS" "$(sid_of "$1")"
}

add_agent() { # add_agent <agents entry JSON>
    jq -c --argjson entry "$1" '. + [$entry]' "$AGENTS" > "$AGENTS.new" && mv "$AGENTS.new" "$AGENTS"
}

# Adds an interactive session with process <pid> whose status changed <idle
# seconds> ago. updatedAt is always recent, so only statusUpdatedAt can give the
# idle time. A non-empty <waiting for> becomes the agent's waitingFor.
# SESSION_ENTRYPOINT replaces the sessions file's entrypoint, "cli".
add_session() { # add_session <pid> <name> <status> <cwd> [<idle seconds>] [<waiting for>]
    local session
    session=$(jq -n -c --argjson pid "$1" --arg sid "$(sid_of "$2")" --arg name "$2" \
        --arg status "$3" --arg cwd "$4" --arg entrypoint "${SESSION_ENTRYPOINT:-cli}" \
        --argjson now "$((NOW * 1000))" --argjson idle "${5-60}" '{
            pid: $pid, sessionId: $sid, cwd: $cwd, startedAt: ($now - 7200000),
            kind: "interactive", entrypoint: $entrypoint, name: $name, status: $status,
            updatedAt: ($now - 5000), statusUpdatedAt: ($now - $idle * 1000)}')
    echo "$session" > "$CONFIG/sessions/$1.json"
    add_agent "$(jq -c --arg waitingFor "${6-}" '{pid, cwd, kind, startedAt, sessionId, status, name}
        + if $waitingFor == "" then {} else {$waitingFor} end' <<<"$session")"
}

# Adds a live interactive session. The sleep is disowned so that stopping it
# prints no job notice.
add_interactive() { # add_interactive <name> <status> <cwd> [<idle seconds>] [<waiting for>]
    local pid
    sleep 300 >/dev/null 2>&1 &
    pid=$!
    disown "$pid"
    SLEEPERS+=("$pid")
    add_session "$pid" "$@"
}

# Prints the pid of a process that has exited and been reaped.
dead_pid() {
    local pid
    sleep 0 &
    pid=$!
    wait "$pid"
    echo "$pid"
}

# Adds a session that `claude agents` listed but that exited before the scan
# reached it: its pid is dead and its sessions/<pid>.json is gone.
add_exited() { # add_exited <name> <cwd>
    local pid
    pid=$(dead_pid)
    add_session "$pid" "$1" idle "$2"
    rm "$CONFIG/sessions/$pid.json"
}

# Adds a background session that started 10 minutes ago. It has an id and a
# state but no pid and no sessions/<pid>.json.
add_background() { # add_background <name> <state> <cwd>
    local sid
    sid=$(sid_of "$1")
    add_agent "$(jq -n -c --arg sid "$sid" --arg name "$1" --arg state "$2" --arg cwd "$3" \
        --argjson now "$((NOW * 1000))" '{
            id: $sid[0:8], cwd: $cwd, kind: "background", startedAt: ($now - 600000),
            sessionId: $sid, state: $state, name: $name}')"
}

# Transcript records in the shapes Claude Code writes. An assistant message
# arrives as one record per content block. write_transcript adds the
# timestamp and session fields.
user_prompt() { jq -n -c --arg t "$1" '{type: "user", message: {role: "user", content: $t}}'; }
assistant_thinking() {
    jq -n -c '{type: "assistant", message: {role: "assistant", content: [{type: "thinking", thinking: "Considering it."}]}}'
}
assistant_text() {
    jq -n -c --arg t "$1" '{type: "assistant", message: {role: "assistant", content: [{type: "text", text: $t}]}}'
}
assistant_bash() { # assistant_bash <tool use id> <command>
    jq -n -c --arg id "$1" --arg cmd "$2" '{type: "assistant", message: {role: "assistant",
        content: [{type: "tool_use", id: $id, name: "Bash", input: {command: $cmd}}]}}'
}
tool_result() { # tool_result <tool use id> <output>
    jq -n -c --arg id "$1" --arg out "$2" \
        '{type: "user", message: {role: "user", content: [{type: "tool_result", tool_use_id: $id, content: $out}]}}'
}

# Writes the session's transcript. The user and assistant records are stamped
# <epoch>. The file's mtime becomes <epoch>.
write_transcript() { # write_transcript <name> <epoch> [<record> ...]
    local path
    path=$(transcript_of "$1")
    printf '%s\n' "${@:3}" | jq -c --arg sid "$(sid_of "$1")" --argjson t "$2" '
        if .type == "user" or .type == "assistant"
        then . + {timestamp: ($t | todate | sub("Z$"; ".000Z")), sessionId: $sid, isSidechain: false}
        else . end' > "$path"
    perl -e 'utime $ARGV[0], $ARGV[0], $ARGV[1] or die "utime: $!\n"' "$2" "$path"
}

# Runs claude-sessions with the fixture, capturing stdout into $OUT, stderr
# into $ERR, and the exit status into $RC. RUN_START and RUN_END hold the epoch
# seconds before and after the run. Perl's alarm kills a run still going after
# 30 seconds, which then exits 142.
run_sessions() { # run_sessions [<claude-sessions arg> ...]
    : > "$CALLS"
    RC=0
    RUN_START=$(date +%s)
    OUT=$(cd "$TESTTMP" && env HOME="$FAKE_HOME" PATH="$SHIM_PATH" CLAUDE_CONFIG_DIR="$CONFIG" \
        AGENTS="$AGENTS" PRS="$PRS" CALLS="$CALLS" \
        perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 30 "$BIN" "$@" 2>"$TESTTMP/err") || RC=$?
    RUN_END=$(date +%s)
    ERR=$(cat "$TESTTMP/err")
}

is_json_array() { jq -e -s 'length == 1 and (.[0] | type == "array")' <<<"$OUT" >/dev/null 2>&1; }

sessions_json() { jq -c '.[]' <<<"$OUT" 2>/dev/null; }

# Prints one value of the session named <name> as text. Null prints nothing.
field() { # field <name> <jq expression>
    sessions_json | jq -r --arg n "$1" "select(.name == \$n) | $2 | values"
}

# Prints one value of the session named <name> as compact JSON, so that an
# assertion can tell null from "" and 0 from "0".
value() { # value <name> <jq expression>
    sessions_json | jq -c --arg n "$1" "select(.name == \$n) | $2"
}

json_names() { sessions_json | jq -r .name | paste -sd ' ' -; }

# The first column of each table row after the header.
table_names() { awk 'NR > 1 { print $1 }' <<<"$OUT" | paste -sd ' ' -; }

# Prints the cell under <column> in the table row of the session named <name>.
# column -t starts each cell at the offset of its column's header. A cell can
# hold spaces.
cell() { # cell <name> <column>
    awk -v name="$1" -v col="$2" '
        NR == 1 {
            line = $0 " "
            start = index(" " line, " " col " ")
            match(substr(line, start + length(col)), /[^ ]/)
            width = RSTART ? length(col) + RSTART - 1 : length(line)
        }
        NR > 1 && $1 == name {
            text = substr($0, start, width)
            sub(/ +$/, "", text)
            print text
        }' <<<"$OUT"
}

# Succeeds when the idle of the session named <name> is the whole minutes from
# <since> to some moment of the last run. <since> is in epoch milliseconds.
idle_since() { # idle_since <name> <since>
    local min=$(((RUN_START * 1000 - $2) / 60000)) max=$(((RUN_END * 1000 + 1000 - $2) / 60000))
    test "$(value "$1" "(.idle | type == \"number\" and . == floor and . >= $min and . <= $max)")" = true
}

# ── Test: the tail holds the last prompt and the last assistant text ─────────

reset_fixture
add_interactive tail idle "$PLAIN"
write_transcript tail $((NOW - 60)) \
    "$(user_prompt "first prompt")" \
    "$(assistant_text "first answer")" \
    "$(user_prompt "latest prompt")" \
    "$(assistant_thinking)" \
    "$(assistant_bash toolu_1 "ls")" \
    "$(tool_result toolu_1 "README.md")" \
    "$(assistant_thinking)" \
    "$(assistant_text "latest answer")" \
    "$(assistant_bash toolu_2 "git status")" \
    "$(tool_result toolu_2 "nothing to commit, working tree clean")" \
    '{"type":"last-prompt","lastPrompt":"latest prompt"}' \
    '{"type":"system","content":"Conversation compacted"}'

run_sessions --json
assert "--json exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "--json prints one JSON array" is_json_array
assert "--json objects carry the documented keys (got '$(value tail keys)')" \
    test "$(value tail 'keys == ["branch","cwd","dirty","idle","kind","name","pid","pr","sessionId","signing","stack","status","tab","tail","transcript","waiting","worktree"]')" = true
assert "--json lists the session by name" test "$(json_names)" = tail
assert "the tail's user text is the last prompt, not a later tool result" \
    test "$(field tail .tail.user)" = "latest prompt"
assert "the tail's assistant text is the last text block, not a later tool call" \
    test "$(field tail .tail.assistant)" = "latest answer"
assert "transcript is the path of the session's transcript" \
    test "$(field tail .transcript)" = "$(transcript_of tail)"
assert "kind comes from claude agents" test "$(field tail .kind)" = interactive
assert "an interactive session's status comes from its status" test "$(field tail .status)" = idle

# ── Test: a cwd outside git leaves the git and PR columns empty ──────────────

for column in branch dirty pr stack signing; do
    assert "a cwd outside git leaves $column null (got '$(value tail ".$column")')" \
        test "$(value tail ".$column")" = null
done
assert_not "a cwd outside git never asks gh" grep -q '^gh ' "$CALLS"

# ── Test: --json with no sessions prints an empty array ──────────────────────

reset_fixture
run_sessions --json
assert "--json with no sessions exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "--json with no sessions prints an empty array (got '$OUT')" \
    test "$(jq -c . <<<"$OUT" 2>/dev/null)" = '[]'

# ── Test: the tail truncates long texts to about 1,000 characters ────────────

LONG_PROMPT=$(printf 'line %04d. ' $(seq 1 150))
LONG_ANSWER=$(printf 'reply %04d. ' $(seq 1 150))

reset_fixture
add_interactive long busy "$PLAIN"
write_transcript long $((NOW - 60)) "$(user_prompt "$LONG_PROMPT")" "$(assistant_text "$LONG_ANSWER")"

run_sessions --json
TAIL_USER=$(field long .tail.user)
TAIL_ASSISTANT=$(field long .tail.assistant)
assert "a long prompt is truncated to about 1,000 characters (got ${#TAIL_USER})" \
    test "${#TAIL_USER}" -ge 950 -a "${#TAIL_USER}" -le 1050
assert "a truncated prompt keeps its start" test "${TAIL_USER:0:900}" = "${LONG_PROMPT:0:900}"
assert "a long assistant text is truncated to about 1,000 characters (got ${#TAIL_ASSISTANT})" \
    test "${#TAIL_ASSISTANT}" -ge 950 -a "${#TAIL_ASSISTANT}" -le 1050
assert "a truncated assistant text keeps its end" \
    test "${TAIL_ASSISTANT: -900}" = "${LONG_ANSWER: -900}"

# ── Test: the tail's user text skips local command entries ───────────────────

# Claude Code records the caveat and the output of a local command, such as
# /model, as user entries.
reset_fixture
add_interactive local idle "$PLAIN"
write_transcript local $((NOW - 60)) \
    "$(user_prompt "review the diff")" \
    "$(assistant_text "The diff looks fine.")" \
    "$(user_prompt "<local-command-caveat>Caveat: The messages below were generated by the user while running local commands.</local-command-caveat>")" \
    "$(user_prompt "<local-command-stdout>Set model to opus</local-command-stdout>")"
# Claude Code records a loaded skill's body and a compaction summary as user
# entries.
add_interactive meta idle "$PLAIN"
write_transcript meta $((NOW - 60)) \
    "$(user_prompt "review the diff")" \
    "$(user_prompt "Base directory for this skill: /skills/go" | jq -c '.isMeta = true')" \
    "$(user_prompt "This session is being continued from a previous conversation." | jq -c '.isCompactSummary = true')"

run_sessions --json
assert "the tail's user text skips local command entries (got '$(field local .tail.user)')" \
    test "$(field local .tail.user)" = "review the diff"
assert "the tail's user text skips skill bodies and compact summaries (got '$(field meta .tail.user)')" \
    test "$(field meta .tail.user)" = "review the diff"

# ── Test: waiting holds what an open prompt waits for ────────────────────────

reset_fixture
add_interactive asks-permission waiting "$PLAIN" 60 "permission prompt"
add_interactive asks-input waiting "$PLAIN" 60 "input needed"
add_interactive unlabeled waiting "$PLAIN" 60
add_interactive resting idle "$PLAIN" 60

run_sessions --json
assert "a waiting session shows its waitingFor (got '$(value asks-permission .waiting)')" \
    test "$(value asks-permission .waiting)" = '"permission prompt"'
assert "a waiting session shows another waitingFor as given (got '$(value asks-input .waiting)')" \
    test "$(value asks-input .waiting)" = '"input needed"'
assert "a waiting session without waitingFor shows input (got '$(value unlabeled .waiting)')" \
    test "$(value unlabeled .waiting)" = '"input"'
assert "a session that is not waiting shows null (got '$(value resting .waiting)')" \
    test "$(value resting .waiting)" = null

# ── Test: --json and the table sort by group, then by idle time ──────────────

# The groups are waiting, then every status but busy, then busy. Within a group
# the session idle longest comes first. claude agents lists the sessions in a
# scrambled order. waiting-1m has been idle the shortest time of all, so only
# its group puts it ahead of the others. The background session has no sessions
# file, so its idle time comes from its transcript's mtime.
reset_fixture
add_interactive busy-2m busy "$PLAIN" 120
add_interactive idle-10m idle "$PLAIN" 600
add_interactive waiting-1m waiting "$PLAIN" 60 "permission prompt"
add_interactive busy-50m busy "$PLAIN" 3000
add_background blocked-25m blocked "$PLAIN"
write_transcript blocked-25m $((NOW - 1530)) "$(user_prompt "run the migration")"
add_interactive waiting-30m waiting "$PLAIN" 1800
add_interactive idle-40m idle "$PLAIN" 2400
SORTED="waiting-30m waiting-1m idle-40m blocked-25m idle-10m busy-50m busy-2m"

run_sessions --json
assert "--json sorts waiting, then not busy, then busy, each longest idle first (got '$(json_names)')" \
    test "$(json_names)" = "$SORTED"

run_sessions
TABLE_HEADER=$(head -n 1 <<<"$OUT" | tr -s ' ')
assert "the table exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "the table header names the columns in order (got '$TABLE_HEADER')" \
    test "$TABLE_HEADER" = "NAME KIND STATUS IDLE WAITING BRANCH DIRTY PR STACK SIGNING TAB WORKTREE"
assert "the table lists the sessions in the --json order (got '$(table_names)')" \
    test "$(table_names)" = "$SORTED"
assert "the table's WAITING column shows the waitingFor words (got '$(cell waiting-1m WAITING)')" \
    test "$(cell waiting-1m WAITING)" = "permission prompt"

# ── Test: idle time comes from the session's last status change ──────────────

# idler's status changed 45.5 minutes ago. Its transcript changed 1 minute ago.
# It started 2 hours ago. bg-transcript started 10 minutes ago. Its transcript
# changed 4.5 minutes ago. bg-new has no transcript. Half minutes keep the
# expected values away from a minute boundary.
reset_fixture
add_interactive idler idle "$PLAIN" 2730
write_transcript idler $((NOW - 60)) "$(user_prompt "wait for me")"
add_background bg-transcript blocked "$PLAIN"
write_transcript bg-transcript $((NOW - 270)) "$(user_prompt "run the migration")"
add_background bg-new blocked "$PLAIN"

run_sessions --json
assert "an interactive session's idle counts from statusUpdatedAt (got '$(value idler .idle)')" \
    idle_since idler $(((NOW - 2730) * 1000))
assert "a background session's idle counts from its transcript's mtime (got '$(value bg-transcript .idle)')" \
    idle_since bg-transcript $(((NOW - 270) * 1000))
assert "a background session without a transcript counts idle from its start (got '$(value bg-new .idle)')" \
    idle_since bg-new $(((NOW - 600) * 1000))

# ── Test: a background session shows its state as its status ────────────────

assert "a background session's kind is background" test "$(field bg-transcript .kind)" = background
assert "a background session's status is its state" test "$(field bg-transcript .status)" = blocked

# ── Test: a session that exited mid-scan is skipped ─────────────────────────

reset_fixture
add_exited gone "$PLAIN"
add_interactive alive idle "$PLAIN"
write_transcript alive $((NOW - 60)) "$(user_prompt "still here")"

run_sessions --json
assert "an exited session does not fail the scan" test "$RC" -eq 0
assert "an exited session is left out and the live one stays" test "$(json_names)" = alive

run_sessions
assert "an exited session does not fail the table" test "$RC" -eq 0
assert "the table leaves out an exited session" test "$(table_names)" = alive

# ── Test: a session with a dead pid is left out despite its sessions file ───

# A session that crashed leaves its sessions/<pid>.json behind.
reset_fixture
add_session "$(dead_pid)" crashed idle "$PLAIN"
write_transcript crashed $((NOW - 60)) "$(user_prompt "still here?")"
add_interactive alive idle "$PLAIN"
write_transcript alive $((NOW - 60)) "$(user_prompt "still here")"

run_sessions --json
assert "a dead pid with a sessions file does not fail the scan" test "$RC" -eq 0
assert "a dead pid with a sessions file is left out (got '$(json_names)')" \
    test "$(json_names)" = alive

# ── Test: an SDK session is left out ────────────────────────────────────────

reset_fixture
SESSION_ENTRYPOINT=sdk-cli add_interactive sdk-child busy "$PLAIN"
write_transcript sdk-child $((NOW - 60)) "$(user_prompt "summarize the diff")"
add_interactive cli-parent idle "$PLAIN"
write_transcript cli-parent $((NOW - 60)) "$(user_prompt "review the PR")"

run_sessions --json
assert "a session whose entrypoint is sdk-cli is left out (got '$(json_names)')" \
    test "$(json_names)" = cli-parent

# ── Git fixture ──────────────────────────────────────────────────────────────

# One repo with a worktree for each of these branches:
# - haacked/topic has PR #9 into haacked/lower, which has PR #10 into main.
# - haacked/upper has PR #11 into haacked/plain, which has no PR.
# - haacked/landed has PR #12 into haacked/lower, which merged.
# - haacked/unpushed was never pushed and has no PR.
# wt-topic is clean. wt-lower has a changed tracked file and an untracked file.
# wt-unpushed has a changed tracked file. wt-upper has only an untracked file.
REPO="$TESTTMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email test@example.com
git -C "$REPO" config user.name "Test"
git -C "$REPO" config commit.gpgsign false
git -C "$REPO" checkout -q -b main
git -C "$REPO" remote add origin git@github.com:haacked/dotfiles.git
echo one > "$REPO/one"
git -C "$REPO" add one
git -C "$REPO" commit -qm one
git -C "$REPO" update-ref refs/remotes/origin/main HEAD
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
for branch in topic lower upper plain landed unpushed; do
    git -C "$REPO" branch "haacked/$branch"
    git -C "$REPO" worktree add -q "$TESTTMP/wt-$branch" "haacked/$branch"
    [ "$branch" = unpushed ] || git -C "$REPO" update-ref "refs/remotes/origin/haacked/$branch" HEAD
done
echo changed > "$TESTTMP/wt-lower/one"
echo new > "$TESTTMP/wt-lower/two"
echo changed > "$TESTTMP/wt-unpushed/one"
echo new > "$TESTTMP/wt-upper/untracked"

# A separate repo that also has a branch named haacked/lower.
OTHER="$TESTTMP/other"
git init -q -b haacked/lower "$OTHER"

pr_json() { # pr_json <number> <head> <base> [<state>]
    jq -n -c --argjson number "$1" --arg head "$2" --arg base "$3" --arg state "${4-OPEN}" '{
        url: "https://github.com/haacked/dotfiles/pull/\($number)", number: $number,
        state: $state, isDraft: false, reviewDecision: "APPROVED", reviews: [],
        headRefName: $head, baseRefName: $base, isCrossRepository: false,
        headRepositoryOwner: {login: "haacked"}, comments: []}'
}

PR_FIXTURE=$(jq -s -c . <<<"$(pr_json 9 haacked/topic haacked/lower)
$(pr_json 10 haacked/lower main)
$(pr_json 11 haacked/upper haacked/plain)
$(pr_json 12 haacked/landed haacked/lower MERGED)")

# The last commit attempt in this transcript failed to sign.
UNSIGNED_COMMIT=(
    "$(user_prompt "commit it")"
    "$(assistant_bash toolu_commit "git commit -m 'Add one'")"
    "$(tool_result toolu_commit "error: gpg failed to sign the data
fatal: failed to write commit object")"
)

# beneath and floor share no word with their branches, so a STACK that names
# the session cannot match on the branch instead.
reset_fixture
echo "$PR_FIXTURE" > "$PRS"
add_interactive topic-session idle "$TESTTMP/wt-topic"
write_transcript topic-session $((NOW - 60)) "${UNSIGNED_COMMIT[@]}"
add_interactive beneath busy "$TESTTMP/wt-lower"
add_interactive climber idle "$TESTTMP/wt-upper"
add_interactive floor idle "$TESTTMP/wt-plain"
add_interactive shipped idle "$TESTTMP/wt-landed"
add_interactive unsigned idle "$TESTTMP/wt-unpushed"
write_transcript unsigned $((NOW - 60)) "${UNSIGNED_COMMIT[@]}"
add_interactive resigned idle "$TESTTMP/wt-unpushed"
write_transcript resigned $((NOW - 60)) "${UNSIGNED_COMMIT[@]}" \
    "$(assistant_bash toolu_retry "git commit -m 'Add one'")" "$(tool_result toolu_retry "[haacked/unpushed 1a2b3c4] Add one")"
add_interactive grepped idle "$TESTTMP/wt-unpushed"
write_transcript grepped $((NOW - 60)) "$(assistant_bash toolu_grep "grep -rn 'failed to sign' notes")" \
    "$(tool_result toolu_grep "notes/x.md: error: gpg failed to sign the data")"
add_interactive busy-unsigned busy "$TESTTMP/wt-unpushed"
write_transcript busy-unsigned $((NOW - 60)) "${UNSIGNED_COMMIT[@]}"
add_interactive untracked-unsigned idle "$TESTTMP/wt-upper"
write_transcript untracked-unsigned $((NOW - 60)) "${UNSIGNED_COMMIT[@]}"

run_sessions --json

# ── Test: a git cwd fills BRANCH, DIRTY, and PR ──────────────────────────────

assert "git sessions exit 0 (stderr: $ERR)" test "$RC" -eq 0
assert "branch is the worktree's branch" test "$(field topic-session .branch)" = haacked/topic
assert "a clean worktree's dirty is 0 (got '$(value topic-session .dirty)')" \
    test "$(value topic-session .dirty)" = 0
assert "dirty counts the changed and the untracked file (got '$(value beneath .dirty)')" \
    test "$(value beneath .dirty)" = 2
assert "pr is the object that git pr --json prints (got '$(value topic-session .pr)')" \
    test "$(value topic-session '.pr == {url: "https://github.com/haacked/dotfiles/pull/9", number: 9,
        state: "OPEN", head: "haacked/topic", base: "haacked/lower", status: "Approved", queue: null}')" = true

# ── Test: a branch without a PR keeps BRANCH and leaves PR empty ─────────────

assert "a branch without a PR still shows its branch" \
    test "$(field unsigned .branch)" = haacked/unpushed
assert "a branch without a PR leaves pr null" test "$(value unsigned .pr)" = null
assert "a branch without a PR leaves stack null" test "$(value unsigned .stack)" = null

# ── Test: STACK names the session that has the base branch checked out ───────

assert "stack names the base branch, its session, and that session's PR (got '$(value topic-session .stack)')" \
    test "$(value topic-session '.stack == {base: "haacked/lower", pr: 10, session: "beneath"}')" = true
assert "stack names the base branch's session without a PR (got '$(value climber .stack)')" \
    test "$(value climber '.stack == {base: "haacked/plain", pr: null, session: "floor"}')" = true

# ── Test: STACK stays empty unless an open PR targets another branch ─────────

assert "an open PR into the default branch leaves stack null (got pr '$(value beneath .pr)')" \
    test "$(value beneath '.pr.base == "main" and .stack == null')" = true
assert "a merged PR into another branch leaves stack null (got pr '$(value shipped .pr)')" \
    test "$(value shipped '.pr.state == "MERGED" and .pr.base == "haacked/lower" and .stack == null')" = true

# ── Test: SIGNING flags an idle session whose commit failed to sign ──────────

assert "an idle, dirty session whose last commit failed to sign shows blocked" \
    test "$(field unsigned .signing)" = blocked
assert "a failed signature in a clean worktree shows null" \
    test "$(value topic-session .signing)" = null
for s in resigned grepped busy-unsigned untracked-unsigned; do
    assert "$s shows no signing block (got '$(value "$s" .signing)')" test "$(value "$s" .signing)" = null
done

# ── Test: the table shows PR and STACK ───────────────────────────────────────

run_sessions
assert "the table's PR column shows the number and status (got '$(cell topic-session PR)')" \
    test "$(cell topic-session PR)" = "#9 Approved"
assert "the table's STACK column shows the base PR and its session (got '$(cell topic-session STACK)')" \
    test "$(cell topic-session STACK)" = "#10 (beneath)"
assert "the table's STACK column shows a base branch without a PR and its session (got '$(cell climber STACK)')" \
    test "$(cell climber STACK)" = "haacked/plain (floor)"

# ── Test: STACK names no session when none in the repo has the base branch ───

# The session named elsewhere has haacked/lower checked out in another repo.
reset_fixture
echo "$PR_FIXTURE" > "$PRS"
add_interactive topic-session idle "$TESTTMP/wt-topic"
add_interactive elsewhere idle "$OTHER"

run_sessions --json
assert "stack names only the base branch (got '$(value topic-session .stack)')" \
    test "$(value topic-session '.stack == {base: "haacked/lower", pr: null, session: null}')" = true

run_sessions
assert "the table's STACK column shows only the base branch (got '$(cell topic-session STACK)')" \
    test "$(cell topic-session STACK)" = haacked/lower

# ── Test: an unknown default branch leaves STACK empty ───────────────────────

reset_fixture
echo "$PR_FIXTURE" > "$PRS"
add_interactive topic-session idle "$TESTTMP/wt-topic"

git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD
run_sessions --json
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
assert "an unknown default branch leaves an open PR's stack null (got '$(value topic-session .stack)')" \
    test "$(value topic-session '.pr.state == "OPEN" and .stack == null')" = true

print_results
