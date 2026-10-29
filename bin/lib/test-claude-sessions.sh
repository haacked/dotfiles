#!/bin/bash
# shellcheck disable=SC2016 # jq programs use $ for their own variables.
# Tests for claude-sessions: the live Claude Code sessions, what each one waits
# on, its git and PR state, and the tail of its transcript.
#
# Usage: test-claude-sessions.sh
#
# Every session comes from a fixture, so every case is offline:
# - A `claude` shim on PATH prints $AGENTS for `claude agents --json`.
# - CLAUDE_CONFIG_DIR holds the sessions/<pid>.json files and the transcripts.
# - A `gh` shim answers `gh pr list` and `gh pr view <url>` from the PRs in
#   $PRS. The real git-pr from this checkout runs against it.
# - A `supacode` shim accepts every call. It fails when $CALLS.fail exists. A
#   read of a worktree's appearance prints $CALLS.appearance, or color=none.
# The controlled PATH keeps system git visible and the real gh, claude, and
# supacode invisible. The shims append one line per call to $CALLS.
#
# The pid of each session that add_interactive adds belongs to a `sleep` that
# this suite starts, so a check that the pid is alive passes. The sleeps have no
# terminal. dead_pid gives the pid of a process that has exited.
#
# --json prints one JSON array, sorted. Each object's keys are the table's
# columns in lowercase, plus cwd, pid, sessionId, transcript, tail
# ({user, assistant}), running ({tool, input, minutes}), and self. An empty
# column is null.
#
# The later tests run the jq module bin/lib/claude-sessions.jq on synthetic
# facts arrays, and then run --plan and --render through the fixture.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/test-trunk-comments.sh
source "$SCRIPT_DIR/test-trunk-comments.sh"

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
# --state, and `gh pr view <url>` with the PR at that URL. `gh api graphql`
# gets the PR that its owner, name, and number variables name. The answer holds
# that PR's graphql field, or a PR with no comments, reviews, or review threads.
# -q or --jq applies to the answer as gh applies it.
echo "gh $*" >> "$CALLS"
prev= head= state= q=. owner= name= number=
for arg; do
    case $prev in
        --head) head=$arg ;;
        --state) state=$arg ;;
        -q | --jq) q=$arg ;;
        -f | -F)
            case $arg in
                owner=*) owner=${arg#*=} ;;
                name=*) name=${arg#*=} ;;
                number=*) number=${arg#*=} ;;
            esac
            ;;
    esac
    prev=$arg
done
case "${1-} ${2-}" in
    "api graphql")
        answer=$(jq -c --arg url "https://github.com/$owner/$name/pull/$number" '
            map(select(.url == $url)) | first // empty
            | {data: {repository: {pullRequest: ({author: {login: "haacked"}, comments: {nodes: []},
                reviews: {nodes: []}, reviewThreads: {nodes: []}} + (.graphql // {}))}}}' "$PRS")
        if [ -z "$answer" ]; then
            echo "gh: Could not resolve to a PullRequest with the number of $number." >&2
            exit 1
        fi
        ;;
    "pr list")
        answer=$(jq -c --arg head "$head" --arg state "${state:-open}" '
            map(select(($head == "" or .headRefName == $head)
                and ($state == "all" or .state == ($state | ascii_upcase))))' "$PRS")
        ;;
    "pr view")
        answer=$(jq -c --arg url "${3-}" 'map(select(.url == $url)) | first // empty' "$PRS")
        if [ -z "$answer" ]; then
            echo "GraphQL: Could not resolve to a PullRequest with the number of ${3##*/}." >&2
            exit 1
        fi
        ;;
    *)
        echo "gh shim: unexpected call: $*" >&2
        exit 1
        ;;
esac
jq -r "$q" <<<"$answer"
SHIM
cat > "$TESTTMP/bin/supacode" <<'SHIM'
#!/bin/bash
echo "supacode $*" >> "$CALLS"
[ ! -e "$CALLS.fail" ] || exit 1
case " $* " in
    *" --color "*) ;;
    *" appearance "*) cat "$CALLS.appearance" 2>/dev/null || echo color=none ;;
esac
SHIM
chmod +x "$TESTTMP/bin/claude" "$TESTTMP/bin/gh" "$TESTTMP/bin/supacode"

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

# Succeeds once ps shows <text> in the environment of process <pid>. Waits up
# to two seconds, because the process may not have run its binary yet.
env_shows() { # env_shows <pid> <text>
    for _ in $(seq 20); do
        ps eww -o command= -p "$1" 2>/dev/null | tr ' ' '\n' | grep -qxF "$2" && return 0
        sleep 0.1
    done
    return 1
}

# Starts a jq that waits to read a FIFO, with the environment <var>=<value>
# ..., and prints its pid. A command substitution starts it, so it is no job of
# this shell and needs no disown.
start_waiter() { # start_waiter <jq> <fifo> <var>=<value> ...
    [ -p "$2" ] || mkfifo "$2"
    env "${@:3}" "$1" . "$2" >/dev/null 2>&1 &
    echo $!
}

# The first jq on PATH whose environment ps shows. ps shows no environment for
# the binaries that macOS ships, such as /usr/bin/jq and sleep.
WAITER=
for candidate in $(type -ap jq); do
    pid=$(start_waiter "$candidate" "$TESTTMP/fifo-probe" SUPACODE_WORKTREE_ID=probe)
    env_shows "$pid" SUPACODE_WORKTREE_ID=probe && WAITER=$candidate
    kill "$pid" 2>/dev/null
    [ -z "$WAITER" ] || break
done

# Adds a live interactive session whose Supacode tab is in the worktree <worktree
# id> at <worktree path>. <worktree path> defaults to <cwd>.
add_supacode() { # add_supacode <name> <status> <cwd> <worktree id> [<worktree path>]
    local pid
    pid=$(start_waiter "$WAITER" "$TESTTMP/fifo-$1" SUPACODE_WORKTREE_ID="$4" \
        SUPACODE_WORKTREE_PATH="${5:-$3}/" SUPACODE_TAB_ID="tab-$1")
    env_shows "$pid" "SUPACODE_WORKTREE_ID=$4" || echo "add_supacode: ps does not show the environment of $1" >&2
    SLEEPERS+=("$pid")
    add_session "$pid" "$1" "$2" "$3"
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
assistant_tool() { # assistant_tool <tool use id> <tool name> <input JSON>
    jq -n -c --arg id "$1" --arg name "$2" --argjson input "$3" '{type: "assistant", message: {role: "assistant",
        content: [{type: "tool_use", id: $id, name: $name, input: $input}]}}'
}
assistant_bash() { # assistant_bash <tool use id> <command>
    assistant_tool "$1" Bash "$(jq -n -c --arg cmd "$2" '{command: $cmd, description: "Run a command"}')"
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
# STDIN is the run's standard input, which is empty when STDIN is unset. When
# SELF_ID is set, even to "", the run gets it as CLAUDE_CODE_SESSION_ID.
run_sessions() { # run_sessions [<claude-sessions arg> ...]
    : > "$CALLS"
    printf '%s' "${STDIN-}" > "$TESTTMP/stdin"
    RC=0
    RUN_START=$(date +%s)
    OUT=$(cd "$TESTTMP" && env HOME="$FAKE_HOME" PATH="$SHIM_PATH" CLAUDE_CONFIG_DIR="$CONFIG" \
        AGENTS="$AGENTS" PRS="$PRS" CALLS="$CALLS" ${SELF_ID+"CLAUDE_CODE_SESSION_ID=$SELF_ID"} \
        perl -e 'alarm shift; exec @ARGV or die "exec: $!\n"' 30 "$BIN" "$@" <"$TESTTMP/stdin" 2>"$TESTTMP/err") || RC=$?
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

# Succeeds when <path> of the session named <name> is the whole minutes from
# <since> to some moment of the last run. <since> is in epoch milliseconds.
minutes_since() { # minutes_since <name> <jq path> <since>
    local min=$(((RUN_START * 1000 - $3) / 60000)) max=$(((RUN_END * 1000 + 1000 - $3) / 60000))
    test "$(value "$1" "($2 | type == \"number\" and . == floor and . >= $min and . <= $max)")" = true
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
    test "$(value tail 'keys == ["branch","cwd","depends","dirty","idle","kind","name","pid","pr","running","self","sessionId","signing","status","supacodeWorktree","tab","tail","transcript","waiting","worktree"]')" = true
assert "--json lists the session by name" test "$(json_names)" = tail
assert "the tail's user text is the last prompt, not a later tool result" \
    test "$(field tail .tail.user)" = "latest prompt"
assert "the tail's assistant text is the last text block, not a later tool call" \
    test "$(field tail .tail.assistant)" = "latest answer"
assert "transcript is the path of the session's transcript" \
    test "$(field tail .transcript)" = "$(transcript_of tail)"
assert "kind comes from claude agents" test "$(field tail .kind)" = interactive
assert "a turn whose tool calls all have results leaves running null (got '$(value tail .running)')" \
    test "$(value tail .running)" = null
assert "an interactive session's status comes from its status" test "$(field tail .status)" = idle

# ── Test: a cwd outside git leaves the git and PR columns empty ──────────────

for column in branch dirty pr depends signing; do
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
    test "$TABLE_HEADER" = "NAME KIND STATUS IDLE WAITING BRANCH DIRTY PR DEPENDS SIGNING TAB WORKTREE"
assert "the table lists the sessions in the --json order (got '$(table_names)')" \
    test "$(table_names)" = "$SORTED"
assert "the table's WAITING column shows the waitingFor words (got '$(cell waiting-1m WAITING)')" \
    test "$(cell waiting-1m WAITING)" = "permission prompt"

# ── Test: running names the tool call that the current turn waits on ────────

# polling's Bash call has run for 20.5 minutes and has no result. parallel made
# two calls in one turn, and only the second has a result. delegating waits on a
# subagent. moved-on's pending call comes before a later prompt, which started a
# new turn. backgrounded's call ran in the background, so its result came at
# once. local-output ran /model while its call waited. The /model output is not
# a prompt.
# long-call's command is about 1,000 characters long. bad-time's call carries a
# timestamp that jq cannot parse.
LONG_COMMAND=$(printf 'echo %04d; ' $(seq 1 100))
reset_fixture
add_interactive polling busy "$PLAIN"
write_transcript polling $((NOW - 1230)) \
    "$(user_prompt "watch CI")" \
    "$(assistant_text "Watching CI.")" \
    "$(assistant_bash toolu_poll "ci-check-status.sh 117397")"
add_interactive parallel busy "$PLAIN"
write_transcript parallel $((NOW - 60)) \
    "$(user_prompt "run both")" \
    "$(assistant_bash toolu_slow "hogli test posthog/api")" \
    "$(assistant_bash toolu_fast "ls")" \
    "$(tool_result toolu_fast "README.md")"
add_interactive delegating busy "$PLAIN"
write_transcript delegating $((NOW - 60)) \
    "$(user_prompt "review it")" \
    "$(assistant_tool toolu_agent Agent '{"description": "Review the diff", "prompt": "Review the diff for bugs."}')"
add_interactive moved-on idle "$PLAIN"
write_transcript moved-on $((NOW - 60)) \
    "$(assistant_bash toolu_old "sleep 600")" \
    "$(user_prompt "never mind, do this instead")"
add_interactive backgrounded busy "$PLAIN"
write_transcript backgrounded $((NOW - 60)) \
    "$(assistant_tool toolu_bg Bash '{"command": "pnpm start", "run_in_background": true}')" \
    "$(tool_result toolu_bg "Command running in background with ID: b1")"
add_interactive local-output busy "$PLAIN"
write_transcript local-output $((NOW - 60)) \
    "$(user_prompt "run the tests")" \
    "$(assistant_bash toolu_tests "bin/test")" \
    "$(user_prompt "<local-command-stdout>Set model to opus</local-command-stdout>")"
add_interactive long-call busy "$PLAIN"
write_transcript long-call $((NOW - 60)) "$(user_prompt "go")" "$(assistant_bash toolu_long "$LONG_COMMAND")"
add_interactive bad-time busy "$PLAIN"
write_transcript bad-time $((NOW - 60)) "$(user_prompt "go")" "$(assistant_bash toolu_bad "make")"
perl -pi -e 's/\.000Z"/+00:00"/' "$(transcript_of bad-time)"

run_sessions --json
RUNNING_INPUT=$(field long-call .running.input)
assert "running names a pending Bash call's tool and command (got '$(value polling .running)')" \
    test "$(value polling '.running | {tool, input}')" = '{"tool":"Bash","input":"ci-check-status.sh 117397"}'
assert "running counts the minutes since the call (got '$(value polling .running.minutes)')" \
    minutes_since polling .running.minutes $(((NOW - 1230) * 1000))
assert "running names the call without a result among parallel calls (got '$(value parallel .running.input)')" \
    test "$(field parallel .running.input)" = "hogli test posthog/api"
assert "running names a pending subagent by its description (got '$(value delegating .running)')" \
    test "$(value delegating '.running | {tool, input}')" = '{"tool":"Agent","input":"Review the diff"}'
assert "a later prompt ends the wait on an earlier call (got '$(value moved-on .running)')" \
    test "$(value moved-on .running)" = null
assert "a background call leaves running null (got '$(value backgrounded .running)')" \
    test "$(value backgrounded .running)" = null
assert "local command output leaves the pending call running (got '$(value local-output .running)')" \
    test "$(field local-output .running.input)" = "bin/test"
assert "a long command is truncated to about 500 characters (got ${#RUNNING_INPUT})" \
    test "${#RUNNING_INPUT}" -ge 450 -a "${#RUNNING_INPUT}" -le 550
assert "a truncated command keeps its start" test "${RUNNING_INPUT:0:450}" = "${LONG_COMMAND:0:450}"
assert "an unparseable timestamp leaves minutes null (got '$(value bad-time .running)')" \
    test "$(value bad-time '.running | {tool, input, minutes}')" = '{"tool":"Bash","input":"make","minutes":null}'

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
    minutes_since idler .idle $(((NOW - 2730) * 1000))
assert "a background session's idle counts from its transcript's mtime (got '$(value bg-transcript .idle)')" \
    minutes_since bg-transcript .idle $(((NOW - 270) * 1000))
assert "a background session without a transcript counts idle from its start (got '$(value bg-new .idle)')" \
    minutes_since bg-new .idle $(((NOW - 600) * 1000))

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
#   PR #9's body also says it depends on #10 being deployed.
# - haacked/upper has PR #11 into haacked/plain, which has no PR.
# - haacked/landed has PR #12 into haacked/lower, which merged. Its body says it
#   depends on #10.
# - haacked/needs has PR #13 into main. Its body names PRs in every form that a
#   "Depends on" line takes, plus #7 in the repo haacked/site, which merged 90.5
#   minutes ago, and #404, which does not exist.
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
for branch in topic lower upper plain landed needs unpushed; do
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

pr_json() { # pr_json <number> <head> <base> [<state>] [<body>]
    jq -n -c --argjson number "$1" --arg head "$2" --arg base "$3" --arg state "${4-OPEN}" --arg body "${5-}" '{
        url: "https://github.com/haacked/dotfiles/pull/\($number)", number: $number,
        state: $state, isDraft: false, reviewDecision: "APPROVED", reviews: [],
        headRefName: $head, baseRefName: $base, isCrossRepository: false, mergeable: "MERGEABLE",
        headRepositoryOwner: {login: "haacked"}, comments: [], body: $body, mergedAt: null}'
}

# Only the "Depends on" lines count. The first line mentions #99 mid-sentence.
NEEDS_BODY='Adds the needy feature, which depends on #99 for its data.

Depends on #10
- Depends on haacked/site#7 once it deploys
**Depends on** https://github.com/haacked/dotfiles/pull/12
Depends on #404'
SITE_MERGED_AT=$((NOW - 5430))

# stamphog approved PR #9, and a person left a review thread on it that nobody
# resolved.
PR_FIXTURE=$(jq -s -c . <<<"$(pr_json 9 haacked/topic haacked/lower OPEN 'Depends on #10 (deployed)' | jq -c '
    .reviews = [{author: {login: "stamphog"}, state: "APPROVED"}]
    | .graphql.reviewThreads.nodes = [{isResolved: false,
        comments: {nodes: [{author: {__typename: "User", login: "dmarchuk"}, isMinimized: false}]}}]')
$(pr_json 10 haacked/lower main)
$(pr_json 11 haacked/upper haacked/plain)
$(pr_json 12 haacked/landed haacked/lower MERGED 'Depends on #10')
$(pr_json 13 haacked/needs main OPEN "$NEEDS_BODY")
$(pr_json 7 haacked/site-docs main MERGED |
    jq -c --argjson at "$SITE_MERGED_AT" '.url = "https://github.com/haacked/site/pull/7" | .mergedAt = ($at | todate)')")

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
add_interactive needy idle "$TESTTMP/wt-needs"

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
        state: "OPEN", head: "haacked/topic", base: "haacked/lower", status: "Approved", queue: null,
        mergeable: "MERGEABLE", mergedAt: null, approvers: ["stamphog"], commenters: ["dmarchuk"]}')" = true

# ── Test: a branch without a PR keeps BRANCH and leaves PR empty ─────────────

assert "a branch without a PR still shows its branch" \
    test "$(field unsigned .branch)" = haacked/unpushed
assert "a branch without a PR leaves pr null" test "$(value unsigned .pr)" = null
assert "a branch without a PR leaves depends null" test "$(value unsigned .depends)" = null

# ── Test: DEPENDS names the PR and the session under a stacked PR ────────────

# PR #9's body names #10 as well. The two edges to #10 become one edge, which
# keeps the body's deploy demand.
assert "depends names the base PR and its session once (got '$(value topic-session .depends)')" \
    test "$(value topic-session '.depends == [{via: "stack", pr: 10, url: "https://github.com/haacked/dotfiles/pull/10",
        base: "haacked/lower", state: "OPEN", merged: null, deploy: true, session: "beneath"}]')" = true
assert "depends names the base branch's session when the branch has no PR (got '$(value climber .depends)')" \
    test "$(value climber '.depends == [{via: "stack", pr: null, url: null,
        base: "haacked/plain", state: null, merged: null, deploy: false, session: "floor"}]')" = true

# ── Test: DEPENDS reads the "Depends on" lines of the PR body ────────────────

assert "depends lists each PR that a Depends on line names, in order (got '$(value needy .depends)')" \
    test "$(value needy '.depends | map(del(.merged)) == [
        {via: "body", pr: 10, url: "https://github.com/haacked/dotfiles/pull/10", base: null,
         state: "OPEN", deploy: false, session: "beneath"},
        {via: "body", pr: 7, url: "https://github.com/haacked/site/pull/7", base: null,
         state: "MERGED", deploy: true, session: null},
        {via: "body", pr: 12, url: "https://github.com/haacked/dotfiles/pull/12", base: null,
         state: "MERGED", deploy: false, session: "shipped"},
        {via: "body", pr: 404, url: "https://github.com/haacked/dotfiles/pull/404", base: null,
         state: null, deploy: false, session: null}]')" = true
assert "merged counts the minutes since the dependency merged (got '$(value needy '.depends[1].merged')')" \
    minutes_since needy '.depends[1].merged' $((SITE_MERGED_AT * 1000))
assert "an open dependency's merged is null (got '$(value needy '.depends[0].merged')')" \
    test "$(value needy '.depends[0].merged')" = null

# ── Test: DEPENDS asks GitHub only about PRs that no live session works on ───

assert_not "a PR that a live session works on is not looked up" \
    grep -q 'gh pr view https://github.com/haacked/dotfiles/pull/10 ' "$CALLS"
assert_not "a base branch that a live session has checked out is not looked up" \
    grep -q -- '--repo haacked/dotfiles --head haacked/' "$CALLS"
assert "a PR that no live session works on is looked up once (got $(grep -c 'pull/7 ' "$CALLS"))" \
    test "$(grep -c 'gh pr view https://github.com/haacked/site/pull/7 ' "$CALLS")" -eq 1

# ── Test: DEPENDS stays empty unless the PR is open and waits on another ─────

assert "an open PR into the default branch without Depends on lines leaves depends null (got pr '$(value beneath .pr)')" \
    test "$(value beneath '.pr.base == "main" and .depends == null')" = true
assert "a merged PR leaves depends null despite its base and its body (got pr '$(value shipped .pr)')" \
    test "$(value shipped '.pr.state == "MERGED" and .depends == null')" = true

# ── Test: SIGNING flags an idle session whose commit failed to sign ──────────

assert "an idle, dirty session whose last commit failed to sign shows blocked" \
    test "$(field unsigned .signing)" = blocked
assert "a failed signature in a clean worktree shows null" \
    test "$(value topic-session .signing)" = null
for s in resigned grepped busy-unsigned untracked-unsigned; do
    assert "$s shows no signing block (got '$(value "$s" .signing)')" test "$(value "$s" .signing)" = null
done

# ── Test: the table shows PR and DEPENDS ─────────────────────────────────────

run_sessions
assert "the table's PR column shows the number and status (got '$(cell topic-session PR)')" \
    test "$(cell topic-session PR)" = "#9 Approved"
assert "the table's DEPENDS column shows the base PR and its session (got '$(cell topic-session DEPENDS)')" \
    test "$(cell topic-session DEPENDS)" = "#10 (beneath)"
assert "the table's DEPENDS column shows a base branch without a PR and its session (got '$(cell climber DEPENDS)')" \
    test "$(cell climber DEPENDS)" = "haacked/plain (floor)"
assert "the table's DEPENDS column names another repo's PR with its repo (got '$(cell needy DEPENDS)')" \
    test "$(cell needy DEPENDS)" = "#10 (beneath), haacked/site#7, #12 (shipped), #404"

# ── Test: a "Depends on" line names #N after any character ───────────────────

# Unlike a tail, a "Depends on" line counts #N right after a word, a slash, or
# a dash.
reset_fixture
jq -s -c . <<<"$(pr_json 13 haacked/needs main OPEN 'Depends on #123/#124
Depends on PR#55
Depends on: #10-#12')" > "$PRS"
add_interactive needy idle "$TESTTMP/wt-needs"
run_sessions --json
assert "depends reads #N after a slash, a word, and a dash (got '$(value needy '[.depends[].pr]')')" \
    test "$(value needy '[.depends[].pr]')" = '[123,124,55,10,12]'

# ── Test: DEPENDS names no session when none in the repo has the base branch ─

# The session named elsewhere has haacked/lower checked out in another repo.
reset_fixture
echo "$PR_FIXTURE" > "$PRS"
add_interactive topic-session idle "$TESTTMP/wt-topic"
add_interactive elsewhere idle "$OTHER"

run_sessions --json
assert "depends finds the base PR on GitHub without a session (got '$(value topic-session .depends)')" \
    test "$(value topic-session '.depends | map({pr, base, session}) == [{pr: 10, base: "haacked/lower", session: null}]')" = true

run_sessions
assert "the table's DEPENDS column shows only the base PR (got '$(cell topic-session DEPENDS)')" \
    test "$(cell topic-session DEPENDS)" = "#10"

# ── Test: an unknown default branch leaves out the stack edge ────────────────

reset_fixture
echo "$PR_FIXTURE" > "$PRS"
add_interactive topic-session idle "$TESTTMP/wt-topic"

git -C "$REPO" symbolic-ref --delete refs/remotes/origin/HEAD
run_sessions --json
git -C "$REPO" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
assert "an unknown default branch keeps only the body edge (got '$(value topic-session .depends)')" \
    test "$(value topic-session '.depends | map({via, pr}) == [{via: "body", pr: 10}]')" = true

# ── Test: a PR under a queued PR takes its queue status ──────────────────────

# Adds a trunk-io comment to the PR object on stdin. <edited> is true when Trunk
# edited the comment after it posted it.
trunk_comment() { # trunk_comment <edited> <body>
    jq -c --argjson edited "$1" --arg body "$2" \
        '.comments += [{author: {login: "trunk-io"}, body: $body, includesCreatedEdit: $edited}]'
}

# PR #11 from haacked/upper sits on PR #9 from haacked/topic, which sits on PR
# #10 from haacked/lower. Only the top PR carries the stack's comment. Two
# sessions work on PR #10. <PR #9 JSON> defaults to an open PR into
# haacked/lower. An empty <PR #9 JSON> leaves haacked/topic without a PR.
run_stack_sessions() { # run_stack_sessions <PR #11 JSON> <PR #10 JSON> [<PR #9 JSON>]
    reset_fixture
    jq -s -c . <<<"$1
${3-$(pr_json 9 haacked/topic haacked/lower)}
$2" > "$PRS"
    add_interactive climber idle "$TESTTMP/wt-upper"
    add_interactive topic-session idle "$TESTTMP/wt-topic"
    add_interactive beneath idle "$TESTTMP/wt-lower"
    add_interactive beneath-twin idle "$TESTTMP/wt-lower"
    run_sessions --json
}

run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic | trunk_comment false "$TRUNK_STACK_POSTED")" \
    "$(pr_json 10 haacked/lower main)"
for s in topic-session beneath beneath-twin; do
    assert "$s takes the queue status of the stack above it (got '$(value "$s" .pr)')" \
        test "$(value "$s" '.pr | {status, queue}')" = \
        '{"status":"Approved, Submitted to Trunk Queue","queue":"Submitted to Trunk Queue"}'
done

run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic | trunk_comment true "$TRUNK_FAILED")" \
    "$(pr_json 10 haacked/lower main)"
assert "a PR under a stack that Trunk removed keeps no queue status (got '$(value beneath .pr)')" \
    test "$(value beneath '.pr | {status, queue}')" = '{"status":"Approved","queue":null}'

run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic | trunk_comment false "$TRUNK_STACK_POSTED")" \
    "$(pr_json 10 haacked/lower main | trunk_comment true "$TRUNK_TESTING")"
assert "a PR with its own queue status keeps it (got '$(value beneath .pr)')" \
    test "$(value beneath '.pr | {status, queue}')" = \
    '{"status":"Approved, Testing in Trunk Queue","queue":"Testing in Trunk Queue"}'

run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic | trunk_comment false "$TRUNK_STACK_POSTED")" \
    "$(pr_json 10 haacked/lower main | trunk_comment true "$TRUNK_FAILED")"
assert "a PR that Trunk removed on its own takes the stack's queue status (got '$(value beneath .pr)')" \
    test "$(value beneath '.pr | {status, queue}')" = \
    '{"status":"Approved, Submitted to Trunk Queue","queue":"Submitted to Trunk Queue"}'

run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic | trunk_comment false "$TRUNK_STACK_POSTED")" \
    "$(pr_json 10 haacked/lower main)" "$(pr_json 9 haacked/topic haacked/lower MERGED)"
assert "a merged PR under a queued PR keeps its status (got '$(value topic-session .pr)')" \
    test "$(value topic-session '.pr | {status, queue}')" = '{"status":"Merged","queue":null}'

run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic | trunk_comment false "$TRUNK_STACK_POSTED")" \
    "$(pr_json 10 haacked/lower main)" "$(pr_json 9 haacked/topic haacked/upper)"
assert "a cycle of stacked sessions finishes before the deadline (rc $RC)" test "$RC" -eq 0
assert "a session in a cycle under a queued PR takes its queue status (got '$(value topic-session .pr.queue)')" \
    test "$(value topic-session .pr.queue)" = '"Submitted to Trunk Queue"'

# PR #11 also names PR #10 in a Depends on line, which carries no queue status.
run_stack_sessions "$(pr_json 11 haacked/upper haacked/topic OPEN 'Depends on #10' |
    trunk_comment false "$TRUNK_STACK_POSTED")" "$(pr_json 10 haacked/lower main)" ''
assert "a session without a PR under a queued PR does not fail the scan (stderr: $ERR)" test "$RC" -eq 0
assert "a session without a PR under a queued PR keeps pr null (got '$(value topic-session .pr)')" \
    test "$(value topic-session .pr)" = null
assert "a PR that a queued PR names in Depends on keeps no queue status (got '$(value beneath .pr)')" \
    test "$(value beneath '.pr | {status, queue}')" = '{"status":"Approved","queue":null}'

# ── jq module fixture ────────────────────────────────────────────────────────

# The module tests run jq from $SHIM_PATH, which is the jq that the script runs
# in this suite. That keeps the module from relying on a newer jq than the
# system's.

PULL=https://github.com/haacked/dotfiles/pull

# Prints one session's facts. <jq update> changes the defaults. Each <jq option>,
# such as --argjson pr <PR JSON>, binds a variable for <jq update>. The default
# tail is not blank, because a blank tail answers every check that reads it.
fact() { # fact <name> [<jq update> [<jq option> ...]]
    jq -n -c --arg name "$1" '{name: $name, kind: "interactive", status: "idle", idle: 30, waiting: null,
        branch: null, dirty: 0, pr: null, depends: null, signing: null, tab: null, worktree: null,
        cwd: "/tmp", pid: 1, sessionId: $name, transcript: null, tail: {user: "", assistant: "Done."},
        running: null, self: false} | '"${2:-.}" "${@:3}"
}

# Prints a PR object. A Merged or Closed <status> gives the PR that state.
fact_pr() { # fact_pr <number> <status> [<jq update>]
    jq -n -c --argjson n "$1" --arg status "$2" '{url: "https://github.com/haacked/dotfiles/pull/\($n)",
        number: $n, state: ({Merged: "MERGED", Closed: "CLOSED"}[$status] // "OPEN"),
        head: "haacked/b\($n)", base: "main", status: $status, queue: null, mergeable: "MERGEABLE",
        mergedAt: null, approvers: [], commenters: []} | '"${3:-.}"
}

# Prints a depends entry on an open PR. An empty <session> is null.
fact_edge() { # fact_edge <number> <session> [<jq update>]
    jq -n -c --argjson n "$1" --arg session "$2" '{via: "body", pr: $n,
        url: "https://github.com/haacked/dotfiles/pull/\($n)", base: null, state: "OPEN", merged: null,
        deploy: false, session: (if $session == "" then null else $session end)} | '"${3:-.}"
}

facts() { printf '%s\n' "$@" | jq -s -c .; } # facts <session facts> ...

# Prints answers that hold <answers> for the session <name> and nothing else.
answer() { # answer <name> <answers JSON>
    jq -n -c --arg n "$1" --argjson a "$2" '{sessions: {($n): $a}}'
}

# Runs the module's <filter> on the facts array <facts>. Prints nothing when jq
# fails.
module() { # module <facts> <filter> [<jq option> ...]
    env PATH="$SHIM_PATH" jq -c -L "$SCRIPT_DIR" "${@:3}" "include \"claude-sessions\"; $2" <<<"$1" 2>/dev/null
}

plan_names() { module "$1" '[plan.sessions[].name]'; } # plan_names <facts>

# Prints the plan entry of the session named <name>, or null when it has none.
plan_entry() { # plan_entry <facts> <name>
    module "$1" 'plan.sessions | map(select(.name == $n)) | first' --arg n "$2"
}

# Prints the session names of the candidate edges in the plan entry of <name>.
edges_of() { plan_entry "$1" "$2" | jq -c '[.edges[]?.session]' 2>/dev/null; } # edges_of <facts> <name>

# Succeeds when the session named <name> has a plan entry without edges.
no_edges() { # no_edges <facts> <name>
    [ "$(plan_entry "$1" "$2" | jq -c 'has("edges")' 2>/dev/null)" = false ]
}

# Prints render's result. <answers> defaults to {}, and <act> defaults to false.
render_json() { # render_json <facts> [<answers>] [<act>]
    local answers=${2:-'{}'} act=${3:-false}
    module "$1" 'render($answers; $act)' --argjson answers "$answers" --argjson act "$act"
}

render_text() { render_json "$@" | jq -r '.text // empty'; } # render_text <facts> [<answers>] [<act>]

render_errors() { render_json "$@" | jq -r '.errors[]?' | sort; } # render_errors <facts> [<answers>]

# Prints judge's result. <answers> defaults to {}.
judged() { # judged <facts> [<answers>]
    local answers=${2:-'{}'}
    module "$1" 'judge($answers)' --argjson answers "$answers"
}

BUCKET_TITLES=$(module '[]' 'buckets | map({(.key): .title}) | add')

# Prints "<group>: <step>" for the session <name> in a judge result.
verdict() { # verdict <judged> <name>
    jq -r --arg n "$2" --argjson titles "$BUCKET_TITLES" \
        '.rows[]? | select(.name == $n) | "\($titles[.bucket]): \(.step)\(.on)"' <<<"$1" 2>/dev/null
}

# Prints the parent of the session <name> in a judge result, with a ? after an
# inferred parent. Prints an empty line for a session without a parent.
parent_of() { # parent_of <judged> <name>
    jq -r --arg n "$2" '.rows[]? | select(.name == $n) | (.parent // "") + (if .inferred then "?" else "" end)' \
        <<<"$1" 2>/dev/null
}

# Prints "<group>: <step>" for the session <name>, judged with <answers> for
# that session alone.
verdict_with() { # verdict_with <facts> <name> <answers JSON>
    verdict "$(judged "$1" "$(answer "$2" "$3")")" "$2"
}

# Asserts that `<function> <text> <name>` prints <expected>, for each pair.
assert_each() { # assert_each <context> <function> <text> <name>=<expected> ...
    local context=$1 fn=$2 text=$3 pair got
    shift 3
    for pair; do
        got=$("$fn" "$text" "${pair%%=*}")
        assert "$context: ${pair%%=*} reads '${pair#*=}' (got '$got')" test "$got" = "${pair#*=}"
    done
}

json_is() { [ "$(jq -c ". == ($2)" <<<"$1" 2>/dev/null)" = true ]; } # json_is <JSON> <expected jq expression>

T7=$(fact t7 '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 7 Draft)")
T8=$(fact t8 '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 8 Draft)")
CONFLICT=$(fact_pr 5 Draft '.mergeable = "CONFLICTING"')

# ── Test: plan of no sessions asks nothing ───────────────────────────────────

PLAN=$(module '[]' plan)
assert "plan of no sessions is {sessions: []} (got '$PLAN')" json_is "$PLAN" '{sessions: []}'

# ── Test: plan leaves out the self session ───────────────────────────────────

FACTS=$(facts "$(fact zed)" "$(fact me '.self = true')" "$(fact alpha)")
assert "plan lists its entries in script order and leaves out self (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '["zed","alpha"]'

# ── Test: an idle session without a PR asks question, offer, and outside ─────

FACTS=$(facts "$(fact asker '.tail.assistant = "Want me to run the tests?"')")
ENTRY=$(plan_entry "$FACTS" asker)
assert "an idle session without a PR asks the tail checks in rule order (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "asker", pr: null, ask: ["question", "offer", "outside"], tail: "Want me to run the tests?"}'
V=$(verdict "$(judged "$FACTS")" asker)
assert "with no answers the session falls through to the last rule (got '$V')" \
    test "$V" = "Needs you: read its last reply and decide what's next"
V=$(verdict_with "$FACTS" asker '{"question": "pick a schema"}')
assert "a question puts the session in Needs you with its step (got '$V')" test "$V" = "Needs you: pick a schema"
V=$(verdict_with "$FACTS" asker '{"offer": "run the tests"}')
assert "an offer puts the session in Claude can continue (got '$V')" test "$V" = "Claude can continue: run the tests"
V=$(verdict_with "$FACTS" asker '{"outside": "CI on #5"}')
assert "an outside wait puts the session in Waiting on something outside (got '$V')" \
    test "$V" = "Waiting on something outside: CI on #5"
V=$(verdict_with "$FACTS" asker '{"question": false, "offer": null, "outside": false}')
assert "false and null answers mean no (got '$V')" test "$V" = "Needs you: read its last reply and decide what's next"
V=$(verdict_with "$FACTS" asker '{"question": "pick a schema", "offer": "run the tests"}')
assert "the first rule whose check is yes wins (got '$V')" test "$V" = "Needs you: pick a schema"

FACTS=$(facts "$(fact interrupted '.running = {tool: "Bash", input: "make", minutes: 9}')")
ENTRY=$(plan_entry "$FACTS" interrupted)
assert "an entry that asks neither stuck nor polling and writes nothing leaves out running (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "interrupted", pr: null, ask: ["question", "offer", "outside"], tail: "Done."}'

# ── Test: a busy session with a finished PR is done ──────────────────────────

FACTS=$(facts \
    "$(fact busy-merged '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 1 Merged)")" \
    "$(fact busy-closed '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 2 Closed)")" \
    "$(fact busy-merged-dirty '.status = "busy" | .dirty = 2 | .pr = $pr' --argjson pr "$(fact_pr 3 Merged)")" \
    "$(fact busy-closed-dirty '.status = "busy" | .dirty = 1 | .pr = $pr' --argjson pr "$(fact_pr 4 Closed)")")
assert_each "a busy session with a finished PR" verdict "$(judged "$FACTS")" \
    "busy-merged=Done: PR merged; archive the worktree once it stops" \
    "busy-closed=Done: PR closed; archive the worktree once it stops" \
    "busy-merged-dirty=Done: PR merged; check its uncommitted changes once it stops" \
    "busy-closed-dirty=Done: PR closed; check its uncommitted changes once it stops"
assert "a busy session with a finished PR asks nothing (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '[]'

# ── Test: a busy session whose last prompt was /exit needs its tab closed ────

FACTS=$(facts \
    "$(fact exit-tag '.status = "busy" | .pr = $pr
        | .tail.user = "<command-name>/exit</command-name>\n<command-message>exit</command-message>"' \
        --argjson pr "$CONFLICT")" \
    "$(fact quit-tag '.status = "busy" | .tail.user = "<command-name>/quit</command-name>"')" \
    "$(fact bare-exit '.status = "busy" | .tail.user = "  /exit\n"')" \
    "$(fact bare-quit '.status = "busy" | .tail.user = "/quit"')" \
    "$(fact exit-mention '.status = "busy" | .tail.user = "/exit the loop once the tests pass"')")
assert_each "an /exit or /quit prompt" verdict "$(judged "$FACTS")" \
    "exit-tag=Needs you: close its tab" \
    "quit-tag=Needs you: close its tab" \
    "bare-exit=Needs you: close its tab" \
    "bare-quit=Needs you: close its tab" \
    "exit-mention=Working: "

# ── Test: a busy session that conflicts with a busy base waits for it ────────

# climber's PR targets base's branch. branch-climber's PR targets floor's
# branch, which has no PR.
FACTS=$(facts \
    "$(fact base '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 10 Draft)")" \
    "$(fact climber '.status = "busy" | .pr = $pr | .depends = [$e]' \
        --argjson pr "$(fact_pr 11 Draft '.mergeable = "CONFLICTING" | .base = "haacked/b10"')" \
        --argjson e "$(fact_edge 10 base '.via = "stack" | .base = "haacked/b10"')")" \
    "$(fact floor '.status = "busy" | .branch = "haacked/plain"')" \
    "$(fact branch-climber '.status = "busy" | .pr = $pr | .depends = [$e]' \
        --argjson pr "$(fact_pr 12 Draft '.mergeable = "CONFLICTING" | .base = "haacked/plain"')" \
        --argjson e "$(fact_edge 0 floor '.via = "stack" | .pr = null | .url = null | .base = "haacked/plain" | .state = null')")")
JUDGED=$(judged "$FACTS")
assert_each "a busy session on a busy base" verdict "$JUDGED" \
    "climber=Held: rebase onto #10 once it settles" \
    "branch-climber=Held: rebase onto haacked/plain once it settles"
assert_each "a busy session on a busy base" parent_of "$JUDGED" \
    "climber=base" \
    "branch-climber=floor"

# ── Test: a busy session on a conflicting PR must rebase unless resolving ────

# Prints a busy session whose pending call is <input>, started <minutes> ago.
busy_call() { # busy_call <name> <tool> <input> <minutes>
    fact "$1" '.status = "busy" | .running = {tool: $tool, input: $input, minutes: $m}' \
        --arg tool "$2" --arg input "$3" --argjson m "$4"
}

# Prints a busy session on the conflicting PR whose pending call is <input>.
conflicting_call() { # conflicting_call <name> <tool> <input>
    busy_call "$1" "$2" "$3" 2 | jq -c --argjson pr "$CONFLICT" '.pr = $pr'
}
FACTS=$(facts \
    "$(fact conflict-no-call '.status = "busy" | .pr = $pr' --argjson pr "$CONFLICT")" \
    "$(conflicting_call conflict-inside-word Bash "bin/emergency-check")" \
    "$(conflicting_call resolve-rebase Bash "git rebase origin/main")" \
    "$(conflicting_call resolve-merge Bash "git MERGE origin/main")" \
    "$(conflicting_call resolve-restack Bash "gt restack")" \
    "$(conflicting_call resolve-skill Skill "/resolve-conflicts 5")")
ANSWERS='{"sessions": {"resolve-rebase": {"step": "resolving it"}, "resolve-merge": {"step": "resolving it"},
    "resolve-restack": {"step": "resolving it"}, "resolve-skill": {"step": "resolving it"}}}'
assert_each "a busy session with a conflicting PR" verdict "$(judged "$FACTS" "$ANSWERS")" \
    "conflict-no-call=Needs you: rebase; the PR conflicts with its base" \
    "conflict-inside-word=Needs you: rebase; the PR conflicts with its base" \
    "resolve-rebase=Working: resolving it" \
    "resolve-merge=Working: resolving it" \
    "resolve-restack=Working: resolving it" \
    "resolve-skill=Working: resolving it"
assert "only the sessions that resolve the conflict reach the checks (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '["resolve-rebase","resolve-merge","resolve-restack","resolve-skill"]'
ENTRY=$(plan_entry "$FACTS" resolve-rebase)
assert "a resolving session asks stuck and polling and writes running (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "resolve-rebase", pr: "#5 Draft", ask: ["stuck", "polling"], write: "running",
        running: {tool: "Bash", input: "git rebase origin/main", minutes: 2}}'

# ── Test: a busy session without a pending call is working ───────────────────

FACTS=$(facts "$(fact quiet-busy '.status = "busy"')")
V=$(verdict "$(judged "$FACTS")" quiet-busy)
assert "a busy session without a pending call is working (got '$V')" test "$V" = "Working: "
assert "a busy session without a pending call asks nothing (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '[]'

# ── Test: the script writes the step for a known poll ──────────────────────

FACTS=$(facts \
    "$(busy_call poll-60 Bash "bin/ci-check-status.sh 117397" 60)" \
    "$(busy_call poll-61 Bash "gh pr checks 5 --watch" 61)" \
    "$(busy_call poll-reviews Bash "wait-for-pending-reviews.sh PostHog/posthog 98865 --timeout 600" 5)" \
    "$(busy_call poll-reviews-stuck Bash "wait-for-pending-reviews.sh PostHog/posthog 98865" 90)" \
    "$(busy_call poll-own-pr Bash "gh pr checks --watch" 5 | jq -c --argjson pr "$(fact_pr 12 Draft)" '.pr = $pr')" \
    "$(busy_call poll-run Bash "gh run watch 123" 5)" \
    "$(busy_call poll-run-stuck Bash "gh run watch 123" 61)" \
    "$(busy_call poll-agent Agent "gh pr checks" 5)")
assert "a known poll asks nothing (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '["poll-agent"]'
ENTRY=$(plan_entry "$FACTS" poll-agent)
assert "a poll command in a tool other than Bash is not a known poll (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "poll-agent", pr: null, ask: ["stuck", "polling"], write: "running",
        running: {tool: "Agent", input: "gh pr checks", minutes: 5}}'
assert_each "a known poll" verdict "$(judged "$FACTS" "$(answer poll-agent '{"step": "gh pr checks (5 min)"}')")" \
    "poll-60=Waiting on something outside: CI on #117397" \
    "poll-61=Needs you: check whether the CI poll on #5 is stuck" \
    "poll-reviews=Waiting on something outside: review of #98865" \
    "poll-reviews-stuck=Needs you: check whether the wait for review of #98865 is stuck" \
    "poll-own-pr=Waiting on something outside: CI on #12" \
    "poll-run=Waiting on something outside: CI" \
    "poll-run-stuck=Needs you: check whether the CI poll is stuck" \
    "poll-agent=Working: gh pr checks (5 min)"

# ── Test: a blank tail answers no to every check that reads it ───────────────

FACTS=$(facts \
    "$(fact cleared '.tail.assistant = " \n" | .pr = $pr' --argjson pr "$(fact_pr 4 "Changes requested")")" \
    "$(fact quiet '.tail.assistant = ""')" \
    "$(fact quiet-busy '.status = "busy" | .tail.assistant = "" | .running = {tool: "Bash", input: "make", minutes: 3}')")
assert "a blank tail asks only the checks that read running (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '["quiet-busy"]'
ASK=$(plan_entry "$FACTS" quiet-busy | jq -c .ask 2>/dev/null)
assert "a busy session with a blank tail still asks stuck and polling (got '$ASK')" test "$ASK" = '["stuck","polling"]'
assert_each "a blank tail" verdict "$(judged "$FACTS" "$(answer quiet-busy '{"step": "make (3 min)"}')")" \
    "cleared=Needs you: address the requested changes" \
    "quiet=Needs you: read its last reply and decide what's next"

# ── Test: a pending call takes the stuck, polling, or running answer ─────────

FACTS=$(facts "$(busy_call run-make Bash "make test" 12)")
ENTRY=$(plan_entry "$FACTS" run-make)
assert "a pending call asks stuck and polling and writes running (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "run-make", pr: null, ask: ["stuck", "polling"], write: "running",
        running: {tool: "Bash", input: "make test", minutes: 12}}'
V=$(verdict_with "$FACTS" run-make '{"stuck": "check whether make test is stuck"}')
assert "a stuck answer puts the session in Needs you (got '$V')" test "$V" = "Needs you: check whether make test is stuck"
V=$(verdict_with "$FACTS" run-make '{"polling": "CI on #5"}')
assert "a polling answer puts the session in Waiting on something outside (got '$V')" \
    test "$V" = "Waiting on something outside: CI on #5"
V=$(verdict_with "$FACTS" run-make '{"stuck": false, "polling": null, "step": "make test (12 min)"}')
assert "with stuck and polling no, the session is working on the step (got '$V')" test "$V" = "Working: make test (12 min)"
ERRORS=$(render_errors "$FACTS")
assert "a pending call without a step reports the step missing (got '$ERRORS')" test "$ERRORS" = "run-make: step is missing"

# ── Test: a finished PR is done unless something is left ─────────────────────

FACTS=$(facts \
    "$(fact done-merged '.pr = $pr' --argjson pr "$(fact_pr 1 Merged)")" \
    "$(fact done-closed '.pr = $pr' --argjson pr "$(fact_pr 2 Closed)")" \
    "$(fact done-stale '.idle = 5000 | .pr = $pr' --argjson pr "$(fact_pr 3 Merged)")" \
    "$(fact done-dirty '.dirty = 3 | .pr = $pr' --argjson pr "$(fact_pr 4 Merged)")" \
    "$(fact done-signing '.dirty = 1 | .signing = "blocked" | .pr = $pr' --argjson pr "$(fact_pr 5 Merged)")" \
    "$(fact done-waiting '.status = "waiting" | .waiting = "permission prompt" | .pr = $pr' \
        --argjson pr "$(fact_pr 6 Merged)")")
assert_each "a finished PR" verdict "$(judged "$FACTS" "$(answer done-waiting '{"step": "approve the prompt"}')")" \
    "done-merged=Done: archive the worktree" \
    "done-closed=Done: archive the worktree" \
    "done-stale=Done: archive the worktree" \
    "done-dirty=Needs you: commit or discard the uncommitted changes" \
    "done-signing=Needs you: retry the commit; signing failed" \
    "done-waiting=Needs you: approve the prompt"
assert "of the finished PRs only the open prompt reaches a check (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '["done-waiting"]'

# ── Test: an open prompt writes its step ─────────────────────────────────────

FACTS=$(facts \
    "$(fact waiter '.status = "waiting" | .waiting = "permission prompt" | .pr = $pr | .tail.assistant = "Merging now."
        | .running = {tool: "Bash", input: "gh pr merge 5", minutes: 1}' --argjson pr "$(fact_pr 5 Approved)")" \
    "$(fact asks-input '.status = "waiting" | .waiting = "input needed"')" \
    "$(fact old-prompt '.status = "waiting" | .waiting = "input needed" | .idle = 4400')")
ENTRY=$(plan_entry "$FACTS" waiter)
assert "an open prompt writes prompt and carries waiting, running, and tail (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "waiter", pr: "#5 Approved", write: "prompt", waiting: "permission prompt",
        running: {tool: "Bash", input: "gh pr merge 5", minutes: 1}, tail: "Merging now."}'
ENTRY=$(plan_entry "$FACTS" asks-input)
assert "an open prompt's entry leaves out a null running (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "asks-input", pr: null, write: "prompt", waiting: "input needed", tail: "Done."}'
W=$(plan_entry "$FACTS" old-prompt | jq -c .write 2>/dev/null)
assert "a stale session's open prompt still writes prompt (got '$W')" test "$W" = '"prompt"'
ANSWERS='{"sessions": {"waiter": {"step": "approve the gh pr merge prompt"}, "asks-input": {"step": "answer its question"},
    "old-prompt": {"step": "answer its old question"}}}'
assert_each "an open prompt" verdict "$(judged "$FACTS" "$ANSWERS")" \
    "waiter=Needs you: approve the gh pr merge prompt" \
    "asks-input=Needs you: answer its question" \
    "old-prompt=Needs you: answer its old question"

# ── Test: a commit that failed to sign needs a retry ─────────────────────────

FACTS=$(facts "$(fact unsigned '.dirty = 1 | .signing = "blocked" | .pr = $pr' --argjson pr "$CONFLICT")")
V=$(verdict "$(judged "$FACTS")" unsigned)
assert "a blocked signature comes before a conflict (got '$V')" test "$V" = "Needs you: retry the commit; signing failed"

# ── Test: a conflicting PR needs a rebase unless its stack base is busy ──────

# on-idle-base's PR targets the branch of idle-base, which is idle.
# body-on-busy's PR names busy-base's PR in a Depends on line.
FACTS=$(facts \
    "$(fact conflicted '.pr = $pr' --argjson pr "$CONFLICT")" \
    "$(fact idle-base '.pr = $pr' --argjson pr "$(fact_pr 20 Draft)")" \
    "$(fact on-idle-base '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 21 Draft '.mergeable = "CONFLICTING"')" \
        --argjson e "$(fact_edge 20 idle-base '.via = "stack"')")" \
    "$(fact busy-base '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 22 Draft)")" \
    "$(fact body-on-busy '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 23 Draft '.mergeable = "CONFLICTING"')" \
        --argjson e "$(fact_edge 22 busy-base)")")
assert_each "a conflicting PR without a busy stack base" verdict "$(judged "$FACTS")" \
    "conflicted=Needs you: rebase; the PR conflicts with its base" \
    "on-idle-base=Needs you: rebase; the PR conflicts with its base" \
    "body-on-busy=Needs you: rebase; the PR conflicts with its base"

# ── Test: a PR that conflicts with a busy base waits and skips offer ─────────

FACTS=$(facts \
    "$(fact moving-base '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 22 Draft)")" \
    "$(fact on-moving '.pr = $pr | .depends = [$e] | .tail.assistant = "Want me to rebase?"' \
        --argjson pr "$(fact_pr 24 Draft '.mergeable = "CONFLICTING"')" \
        --argjson e "$(fact_edge 22 moving-base '.via = "stack"')")")
ENTRY=$(plan_entry "$FACTS" on-moving)
assert "a busy base keeps the offer check out of the plan (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "on-moving", pr: "#24 Draft", ask: ["question", "outside"], tail: "Want me to rebase?"}'
JUDGED=$(judged "$FACTS")
assert_each "a conflicting PR on a busy base" verdict "$JUDGED" "on-moving=Held: rebase onto #22 once it settles"
assert_each "a conflicting PR on a busy base" parent_of "$JUDGED" "on-moving=moving-base"

# ── Test: a PR that Trunk removed from its queue needs a look ────────────────

FACTS=$(facts "$(fact removed '.pr = $pr' \
    --argjson pr "$(fact_pr 5 "Approved, Removed from Trunk Queue" '.queue = "Removed from Trunk Queue"')")")
V=$(verdict "$(judged "$FACTS")" removed)
assert "a PR that Trunk removed needs the user (got '$V')" test "$V" = "Needs you: find out why Trunk removed the PR"
assert "a PR that Trunk removed asks nothing (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '[]'

# ── Test: an approved, unqueued PR without a dependency needs enqueueing ─────

# merged-dep's only edge names a PR that merged, which is not a dependency.
FACTS=$(facts \
    "$(fact enqueue '.pr = $pr' --argjson pr "$(fact_pr 1 Approved)")" \
    "$(fact queue-unknown '.pr = $pr' --argjson pr "$(fact_pr 2 Approved '.queue = "unknown" | .commenters = ["alice"]')")" \
    "$(fact comments-unloaded '.pr = $pr' --argjson pr "$(fact_pr 3 Approved '.commenters = null')")" \
    "$(fact comments-two '.pr = $pr' --argjson pr "$(fact_pr 4 Approved '.commenters = ["alice", "bob"]')")" \
    "$(fact comments-one '.pr = $pr' --argjson pr "$(fact_pr 5 Approved '.commenters = ["alice"]')")" \
    "$(fact merged-dep '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 6 Approved)" \
        --argjson e "$(fact_edge 40 '' '.state = "MERGED" | .merged = 30')")")
assert_each "an approved, unqueued PR" verdict "$(judged "$FACTS")" \
    "enqueue=Needs you: enqueue the PR" \
    "queue-unknown=Needs you: check whether Trunk queued it; its queue status did not load" \
    "comments-unloaded=Needs you: check for reviewer comments, then enqueue; they did not load" \
    "comments-two=Needs you: read the comments from alice and bob, then enqueue" \
    "comments-one=Needs you: read the comments from alice, then enqueue" \
    "merged-dep=Needs you: enqueue the PR"
assert "an approved, unqueued PR asks nothing (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '[]'

# ── Test: tints marks a PR that Trunk can take now ready, and a queued PR ────

# A queued PR stays queued even when it conflicts or waits on a PR. guess names
# #2 in its tail, so it may wait on queued's PR. shared-a and shared-b work in
# one worktree and disagree.
FACTS=$(facts \
    "$(fact ready '.pr = $pr | .supacodeWorktree = "w-ready"' --argjson pr "$(fact_pr 1 Approved)")" \
    "$(fact queued '.pr = $pr | .supacodeWorktree = "w-queued"' \
        --argjson pr "$(fact_pr 2 "Approved, Submitted to Trunk Queue" '.queue = "Submitted to Trunk Queue"')")" \
    "$(fact queued-dep '.pr = $pr | .depends = [$e] | .supacodeWorktree = "w-queued-dep"' \
        --argjson pr "$(fact_pr 14 "Approved, Testing in Trunk Queue" '.queue = "Testing in Trunk Queue" | .mergeable = "CONFLICTING"')" \
        --argjson e "$(fact_edge 42 '')")" \
    "$(fact unknown '.pr = $pr | .supacodeWorktree = "w-unknown"' --argjson pr "$(fact_pr 3 Approved '.queue = "unknown"')")" \
    "$(fact removed '.pr = $pr | .supacodeWorktree = "w-removed"' \
        --argjson pr "$(fact_pr 4 "Approved, Removed from Trunk Queue" '.queue = "Removed from Trunk Queue"')")" \
    "$(fact conflicting '.pr = $pr | .supacodeWorktree = "w-conflicting"' \
        --argjson pr "$(fact_pr 5 Approved '.mergeable = "CONFLICTING"')")" \
    "$(fact open-dep '.pr = $pr | .depends = [$e] | .supacodeWorktree = "w-open-dep"' \
        --argjson pr "$(fact_pr 6 Approved)" --argjson e "$(fact_edge 40 '')")" \
    "$(fact merged-dep '.pr = $pr | .depends = [$e] | .supacodeWorktree = "w-merged-dep"' \
        --argjson pr "$(fact_pr 7 Approved)" --argjson e "$(fact_edge 41 '' '.state = "MERGED" | .merged = 30')")" \
    "$(fact closed-dep '.pr = $pr | .depends = [$e] | .supacodeWorktree = "w-closed-dep"' \
        --argjson pr "$(fact_pr 15 Approved)" --argjson e "$(fact_edge 43 '' '.state = "CLOSED"')")" \
    "$(fact merged-base '.pr = $pr | .depends = [$e] | .supacodeWorktree = "w-merged-base"' \
        --argjson pr "$(fact_pr 16 Approved)" \
        --argjson e "$(fact_edge 44 '' '.via = "stack" | .base = "haacked/b44" | .state = "MERGED" | .merged = 10')")" \
    "$(fact guess '.pr = $pr | .tail.assistant = "This goes out after #2." | .supacodeWorktree = "w-guess"' \
        --argjson pr "$(fact_pr 8 Approved)")" \
    "$(fact review '.pr = $pr | .supacodeWorktree = "w-review"' --argjson pr "$(fact_pr 9 "Review required")")" \
    "$(fact landed '.pr = $pr | .supacodeWorktree = "w-landed"' --argjson pr "$(fact_pr 10 Merged)")" \
    "$(fact closed '.pr = $pr | .supacodeWorktree = "w-closed"' --argjson pr "$(fact_pr 11 Closed)")" \
    "$(fact no-tab '.pr = $pr' --argjson pr "$(fact_pr 12 Approved)")" \
    "$(fact shared-a '.pr = $pr | .supacodeWorktree = "w-shared"' --argjson pr "$(fact_pr 13 Approved)")" \
    "$(fact shared-b '.pr = $pr | .supacodeWorktree = "w-shared"' --argjson pr "$(fact_pr 13 "Changes requested")")")
TINTS=$(module "$FACTS" '[tints] | sort')
assert "tints marks only an approved, unqueued PR without a dependency ready, and each queued PR queued (got '$TINTS')" \
    json_is "$TINTS" '["merged\tw-landed", "open\tw-closed-dep", "open\tw-conflicting", "open\tw-guess",
        "open\tw-merged-base", "open\tw-open-dep",
        "open\tw-removed", "open\tw-review", "open\tw-shared", "open\tw-unknown",
        "queued\tw-queued", "queued\tw-queued-dep", "ready\tw-merged-dep", "ready\tw-ready"]'

# ── Test: an approved PR with a dependency waits on it ───────────────────────

FACTS=$(facts \
    "$(fact open-dep '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 1 Approved)" --argjson e "$(fact_edge 40 '')")" \
    "$(fact null-dep '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 2 Approved)" \
        --argjson e "$(fact_edge 41 '' '.state = null')")")
ENTRY=$(plan_entry "$FACTS" open-dep)
assert "an approved PR with a dependency asks the tail checks (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "open-dep", pr: "#1 Approved", ask: ["question", "offer", "outside"], tail: "Done."}'
assert_each "an approved PR with a dependency" verdict "$(judged "$FACTS")" \
    "open-dep=Held: waits on #40" \
    "null-dep=Held: waits on #41"

# ── Test: a PR whose stack base merged needs a retarget ──────────────────────

FACTS=$(facts \
    "$(fact retarget '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 30 Draft)" \
        --argjson e "$(fact_edge 29 '' '.via = "stack" | .base = "haacked/b29" | .state = "MERGED" | .merged = 10')")" \
    "$(fact body-merged '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 31 Draft)" \
        --argjson e "$(fact_edge 29 '' '.state = "MERGED" | .merged = 10')")")
assert_each "a merged base" verdict "$(judged "$FACTS")" \
    "retarget=Needs you: retarget the PR; its base #29 merged" \
    "body-merged=Needs you: read its last reply and decide what's next"
assert "a merged stack base asks nothing, and a merged body edge does not stop the walk (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '["body-merged"]'

# ── Test: a dependency that closed unmerged needs a replacement ──────────────

FACTS=$(facts \
    "$(fact body-closed '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 32 Draft)" \
        --argjson e "$(fact_edge 28 '' '.state = "CLOSED"')")" \
    "$(fact stack-closed '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 33 Draft)" \
        --argjson e "$(fact_edge 27 '' '.via = "stack" | .base = "haacked/b27" | .state = "CLOSED"')")")
assert_each "a closed dependency" verdict "$(judged "$FACTS")" \
    "body-closed=Needs you: decide what replaces #28, which closed unmerged" \
    "stack-closed=Needs you: decide what replaces #27, which closed unmerged"
assert "a closed dependency asks nothing (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '[]'

# ── Test: requested changes need the user unless they wait elsewhere ─────────

FACTS=$(facts "$(fact changes '.pr = $pr | .tail.assistant = "The API team owns the next step."' \
    --argjson pr "$(fact_pr 5 "Changes requested")")")
ENTRY=$(plan_entry "$FACTS" changes)
assert "requested changes ask waits_elsewhere before the other tail checks (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "changes", pr: "#5 Changes requested", ask: ["waits_elsewhere", "question", "offer", "outside"],
        tail: "The API team owns the next step."}'
V=$(verdict "$(judged "$FACTS")" changes)
assert "requested changes with no answers need the user (got '$V')" test "$V" = "Needs you: address the requested changes"
V=$(verdict_with "$FACTS" changes '{"waits_elsewhere": false}')
assert "requested changes with waits_elsewhere false need the user (got '$V')" \
    test "$V" = "Needs you: address the requested changes"
V=$(verdict_with "$FACTS" changes '{"waits_elsewhere": true, "outside": "a reply from the API team"}')
assert "requested changes that wait elsewhere take the later checks (got '$V')" \
    test "$V" = "Waiting on something outside: a reply from the API team"
V=$(verdict_with "$FACTS" changes '{"waits_elsewhere": true}')
assert "requested changes that wait elsewhere fall through to the last rule (got '$V')" \
    test "$V" = "Needs you: read its last reply and decide what's next"

# ── Test: only an idle session gets the offer check ──────────────────────────

FACTS=$(facts "$(fact blocked-bg '.kind = "background" | .status = "blocked" | .tail.assistant = "Want me to continue?"')")
ENTRY=$(plan_entry "$FACTS" blocked-bg)
assert "a session that is not idle gets no offer check (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "blocked-bg", pr: null, ask: ["question", "outside"], tail: "Want me to continue?"}'
ERRORS=$(render_errors "$FACTS" "$(answer blocked-bg '{"offer": "continue"}')")
assert "an offer answer for a session that is not idle is refused (got '$ERRORS')" \
    test "$ERRORS" = "blocked-bg: offer was not asked"

# ── Test: a queued PR waits on the Trunk queue and gets no offer check ───────

FACTS=$(facts "$(fact queued '.pr = $pr' \
    --argjson pr "$(fact_pr 5 "Approved, Testing in Trunk Queue" '.queue = "Testing in Trunk Queue"')")")
ENTRY=$(plan_entry "$FACTS" queued)
assert "a queued PR asks only question (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "queued", pr: "#5 Approved, Testing in Trunk Queue", ask: ["question"], tail: "Done."}'
V=$(verdict "$(judged "$FACTS")" queued)
assert "a queued PR waits on the Trunk queue (got '$V')" test "$V" = "Waiting on something outside: Trunk queue on #5"

# ── Test: a PR that needs a review waits on it ───────────────────────────────

FACTS=$(facts \
    "$(fact review '.pr = $pr' --argjson pr "$(fact_pr 6 "Review required")")" \
    "$(fact not-approved '.pr = $pr' --argjson pr "$(fact_pr 7 "Not approved")")" \
    "$(fact review-unknown '.pr = $pr' --argjson pr "$(fact_pr 8 "Review required" '.queue = "unknown"')")")
ENTRY=$(plan_entry "$FACTS" review)
assert "a PR that needs a review asks question and offer (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "review", pr: "#6 Review required", ask: ["question", "offer"], tail: "Done."}'
ASK=$(plan_entry "$FACTS" review-unknown | jq -c .ask 2>/dev/null)
assert "a queue status that did not load keeps the offer check out (got '$ASK')" test "$ASK" = '["question"]'
assert_each "a PR that needs a review" verdict "$(judged "$FACTS")" \
    "review=Waiting on something outside: review of #6" \
    "not-approved=Waiting on something outside: review of #7" \
    "review-unknown=Waiting on something outside: review of #8"

# ── Test: a merged dependency that must deploy waits on the deploy ───────────

# Prints an idle session whose PR depends on the deploy of PR #7, which merged
# <minutes> ago.
deploy_wait() { # deploy_wait <name> <minutes, or null>
    fact "$1" '.pr = $pr | .depends = [$e | .merged = $m]' --argjson pr "$(fact_pr 5 Draft)" \
        --argjson e "$(fact_edge 7 '' '.state = "MERGED" | .deploy = true')" --argjson m "$2"
}
FACTS=$(facts "$(deploy_wait deploy-90 90 | jq -c '.tail.assistant = "Merged; the deploy is next."')")
ENTRY=$(plan_entry "$FACTS" deploy-90)
assert "a merged dependency to deploy asks past_deploy and names the deploy (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "deploy-90", pr: "#5 Draft", ask: ["question", "offer", "past_deploy", "outside"],
        deploy: "#7 (merged 1h ago)", tail: "Merged; the deploy is next."}'
V=$(verdict "$(judged "$FACTS")" deploy-90)
assert "with no answers the session waits on the deploy (got '$V')" \
    test "$V" = "Waiting on something outside: deploy of #7 (merged 1h ago)"
V=$(verdict_with "$FACTS" deploy-90 '{"past_deploy": true}')
assert "a session past the deploy falls through to the last rule (got '$V')" \
    test "$V" = "Needs you: read its last reply and decide what's next"

FACTS=$(facts "$(deploy_wait merged-59 59)" "$(deploy_wait merged-60 60)" "$(deploy_wait merged-2879 2879)" \
    "$(deploy_wait merged-2880 2880)" "$(deploy_wait merged-null null)")
assert_each "the deploy's age" verdict "$(judged "$FACTS")" \
    "merged-59=Waiting on something outside: deploy of #7 (merged 59m ago)" \
    "merged-60=Waiting on something outside: deploy of #7 (merged 1h ago)" \
    "merged-2879=Waiting on something outside: deploy of #7 (merged 47h ago)" \
    "merged-2880=Waiting on something outside: deploy of #7 (merged 2d ago)" \
    "merged-null=Waiting on something outside: deploy of #7"

# ── Test: a session idle for more than two days is stale ─────────────────────

FACTS=$(facts "$(fact old-2881 '.idle = 2881')" "$(fact old-4400 '.idle = 4400')")
assert_each "a stale session" verdict "$(judged "$FACTS")" \
    "old-2881=Stale: idle for 2d; resume or close it" \
    "old-4400=Stale: idle for 3d; resume or close it"
assert "a stale session asks nothing (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '[]'

# ── Test: a stale session with an approved, unqueued PR needs enqueueing ─────

FACTS=$(facts "$(fact old-approved '.idle = 2881 | .pr = $pr | .tail.assistant = "Waiting on a reviewer."' \
    --argjson pr "$(fact_pr 5 Approved)")")
V=$(verdict "$(judged "$FACTS")" old-approved)
assert "a stale session's approved, unqueued PR still needs the user (got '$V')" test "$V" = "Needs you: enqueue the PR"
assert "a stale session with an approved PR asks nothing (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '[]'

# ── Test: a stale session whose only signal is its tail is stale ─────────────

# The tail says that the session waits on a reviewer, which was true 21 days ago.
FACTS=$(facts "$(fact old-tail '.kind = "background" | .status = "blocked" | .idle = 30240
    | .tail.assistant = "Waiting on a reviewer for this one."')")
V=$(verdict "$(judged "$FACTS")" old-tail)
assert "a stale session whose tail says it waits is still stale (got '$V')" test "$V" = "Stale: idle for 21d; resume or close it"
assert "a stale session's tail reaches no check (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '[]'

# ── Test: a stale session gets no tail checks and no candidate edges ─────────

FACTS=$(facts "$T7" \
    "$(fact old-changes '.idle = 4400 | .pr = $pr | .tail.assistant = "This waits on #7."' \
        --argjson pr "$(fact_pr 5 "Changes requested")")" \
    "$(fact old-mention '.idle = 4400 | .tail.assistant = "Want me to rebase onto #7?"')")
assert "a stale session gets no ask and no edges (got '$(plan_names "$FACTS")')" test "$(plan_names "$FACTS")" = '[]'
assert_each "a stale session" verdict "$(judged "$FACTS")" \
    "old-changes=Stale: idle for 3d; resume or close it" \
    "old-mention=Stale: idle for 3d; resume or close it"

# ── Test: a session idle for exactly two days is not stale ───────────────────

FACTS=$(facts "$(fact two-days '.idle = 2880 | .tail.assistant = "Waiting on a reviewer."')")
ENTRY=$(plan_entry "$FACTS" two-days)
assert "a session idle for 2880 minutes asks the tail checks (got '$ENTRY')" \
    json_is "$ENTRY" '{name: "two-days", pr: null, ask: ["question", "offer", "outside"], tail: "Waiting on a reviewer."}'
V=$(verdict "$(judged "$FACTS")" two-days)
assert "a session idle for 2880 minutes is not stale (got '$V')" \
    test "$V" = "Needs you: read its last reply and decide what's next"

# ── Test: a candidate edge comes from a bare #N, a URL, or owner/repo#N ──────

FACTS=$(facts "$T7" "$T8" \
    "$(fact by-number '.tail.assistant = "This stacks on #7."')" \
    "$(fact by-url '.tail.assistant = "Blocked until https://github.com/Haacked/DotFiles/pull/8 merges."')" \
    "$(fact by-repo '.tail.assistant = "It follows haacked/dotfiles#8."')")
assert_each "a candidate edge" edges_of "$FACTS" \
    'by-number=["t7"]' \
    'by-url=["t8"]' \
    'by-repo=["t8"]'
ENTRY=$(plan_entry "$FACTS" by-number)
assert "a candidate edge is {session, pr} with the PR's number (got '$ENTRY')" \
    json_is "$(jq -c .edges <<<"$ENTRY" 2>/dev/null)" '[{session: "t7", pr: 7}]'
assert "an entry with a candidate also asks its checks and carries its tail (got '$ENTRY')" \
    json_is "$(jq -c 'del(.edges)' <<<"$ENTRY" 2>/dev/null)" \
    '{name: "by-number", pr: null, ask: ["question", "offer", "outside"], tail: "This stacks on #7."}'

# ── Test: candidate edges keep the order of first mention, once per session ──

FACTS=$(facts "$T7" "$T8" \
    "$(fact mentions '.tail.assistant = "After (#8) lands, and once #7 does, rebase on https://github.com/haacked/dotfiles/pull/8."')")
E=$(edges_of "$FACTS" mentions)
assert "candidate edges keep the order of first mention, once per session (got '$E')" test "$E" = '["t8","t7"]'

# ── Test: a bare #N that two repos share matches no session ──────────────────

SITE7=$(fact site7 '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 7 Draft '.url = "https://github.com/haacked/site/pull/7"')")
FACTS=$(facts "$T7" "$SITE7" \
    "$(fact shared '.tail.assistant = "This waits on #7."')" \
    "$(fact qualified '.tail.assistant = "This waits on haacked/site#7."')")
assert "a bare #N that two repos share gives no candidate (got '$(plan_entry "$FACTS" shared)')" no_edges "$FACTS" shared
E=$(edges_of "$FACTS" qualified)
assert "owner/repo#N picks the session in that repo (got '$E')" test "$E" = '["site7"]'

# ── Test: a candidate names the first session in script order on that PR ─────

FACTS=$(facts \
    "$(fact twin-a '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 7 Draft)")" \
    "$(fact twin-b '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 7 Draft)")" \
    "$(fact on-twins '.tail.assistant = "This waits on #7."')")
E=$(edges_of "$FACTS" on-twins)
assert "a PR that two sessions work on gives one candidate, the first in script order (got '$E')" test "$E" = '["twin-a"]'

# ── Test: own, listed, and merged PRs are not candidates ─────────────────────

FACTS=$(facts "$T7" \
    "$(fact t9 '.pr = $pr' --argjson pr "$(fact_pr 9 Merged)")" \
    "$(fact own '.pr = $pr | .tail.assistant = "#5 is ready for review."' --argjson pr "$(fact_pr 5 Draft)")" \
    "$(fact listed '.pr = $pr | .depends = [$e] | .tail.assistant = "This waits on #7."' \
        --argjson pr "$(fact_pr 6 Draft)" --argjson e "$(fact_edge 7 t7)")" \
    "$(fact after-merged '.tail.assistant = "This came after #9."')" \
    "$(fact glued '.tail.assistant = "See foo#7, bar-#7, v1.#7, and x/#7."')")
for s in own listed after-merged glued; do
    assert "$s gets no candidate edge (got '$(plan_entry "$FACTS" "$s")')" no_edges "$FACTS" "$s"
done

# ── Test: stale, finished, and self sessions get no candidates ───────────────

# me is the self session, so a candidate may name it.
FACTS=$(facts "$T7" \
    "$(fact me '.self = true | .status = "busy" | .pr = $pr | .tail.assistant = "This waits on #7."' \
        --argjson pr "$(fact_pr 8 Draft)")" \
    "$(fact old '.idle = 4400 | .tail.assistant = "This waits on #7."')" \
    "$(fact finished '.pr = $pr | .tail.assistant = "This waited on #7."' --argjson pr "$(fact_pr 5 Merged)")" \
    "$(fact on-me '.tail.assistant = "This waits on #8."')")
assert "only the session that is not stale, finished, or self has an entry (got '$(plan_names "$FACTS")')" \
    test "$(plan_names "$FACTS")" = '["on-me"]'
E=$(edges_of "$FACTS" on-me)
assert "a candidate may name the self session (got '$E')" test "$E" = '["me"]'

# ── Test: a busy session gets candidate edges too ────────────────────────────

FACTS=$(facts "$T7" "$(fact busy-mention '.status = "busy" | .tail.assistant = "Rebasing onto #7 next."')")
ENTRY=$(plan_entry "$FACTS" busy-mention)
assert "a busy session's entry carries its candidates and tail (got '$ENTRY')" \
    json_is "$(jq -c 'del(.edges)' <<<"$ENTRY" 2>/dev/null)" '{name: "busy-mention", pr: null, tail: "Rebasing onto #7 next."}'
E=$(edges_of "$FACTS" busy-mention)
assert "a busy session's candidate names the session (got '$E')" test "$E" = '["t7"]'

# ── Test: an accepted candidate holds an approved PR under the PR's session ──

FACTS=$(facts \
    "$(fact stacker '.pr = $pr | .tail.assistant = "This stacks on #7."' --argjson pr "$(fact_pr 5 Approved)")" \
    "$T7" \
    "$(fact follower '.tail.assistant = "I will continue after #7 merges."')")
ENTRY=$(plan_entry "$FACTS" stacker)
assert "an unknown candidate to an open PR makes an approved PR ask the later checks (got '$ENTRY')" \
    json_is "$(jq -c 'del(.edges)' <<<"$ENTRY" 2>/dev/null)" \
    '{name: "stacker", pr: "#5 Approved", ask: ["question", "offer", "outside"], tail: "This stacks on #7."}'
E=$(edges_of "$FACTS" stacker)
assert "an approved PR's candidate names the session (got '$E')" test "$E" = '["t7"]'
ANSWERS='{"sessions": {"stacker": {"edges": ["t7"]}, "follower": {"edges": ["t7"]}}}'
JUDGED=$(judged "$FACTS" "$ANSWERS")
assert_each "an accepted candidate" parent_of "$JUDGED" "stacker=t7?" "follower=t7?"
assert_each "an accepted candidate" verdict "$JUDGED" "stacker=Held: waits on #7" "follower=Held: waits on #7"
TEXT=$(render_text "$FACTS" "$ANSWERS")
EXPECTED='2 held · 1 working

**Held (2):** `stacker`: waits on #7, waits on `t7` (inferred) · `follower`: waits on #7, waits on `t7` (inferred)

**Working (1):** `t7`: 2 wait on it'
assert "an inferred parent prints with (inferred) (got '$TEXT')" test "$TEXT" = "$EXPECTED"
V=$(verdict_with "$FACTS" stacker '{"edges": []}')
assert "a rejected candidate leaves an approved PR to enqueue (got '$V')" test "$V" = "Needs you: enqueue the PR"

# ── Test: an accepted candidate to a closed PR needs a replacement ───────────

FACTS=$(facts \
    "$(fact closer '.pr = $pr' --argjson pr "$(fact_pr 12 Closed)")" \
    "$(fact replacer '.tail.assistant = "This replaces the work in #12."')")
ENTRY=$(plan_entry "$FACTS" replacer)
E=$(edges_of "$FACTS" replacer)
assert "a closed PR can be a candidate (got '$E')" test "$E" = '["closer"]'
assert "an unknown candidate to a closed PR keeps the walk going (got '$ENTRY')" \
    test "$(jq -c .ask <<<"$ENTRY" 2>/dev/null)" = '["question","offer","outside"]'
JUDGED=$(judged "$FACTS" "$(answer replacer '{"edges": ["closer"]}')")
assert_each "an accepted candidate to a closed PR" verdict "$JUDGED" \
    "replacer=Needs you: decide what replaces #12, which closed unmerged"
assert_each "an accepted candidate to a closed PR" parent_of "$JUDGED" "replacer="
V=$(verdict "$(judged "$FACTS")" replacer)
assert "a rejected candidate to a closed PR changes nothing (got '$V')" \
    test "$V" = "Needs you: read its last reply and decide what's next"

# ── Test: a session's parent is the session it depends on ────────────────────

# r has two children, c1 and c2. g1's parent is c1, and gg's parent is g1. g2's
# parent is c2.
FACTS=$(facts \
    "$(fact g1 '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 4 Draft)" --argjson e "$(fact_edge 2 c1)")" \
    "$(fact r '.signing = "blocked" | .pr = $pr' --argjson pr "$(fact_pr 1 Draft)")" \
    "$(fact c1 '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 2 Draft)" --argjson e "$(fact_edge 1 r)")" \
    "$(fact gg '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 6 Draft)" --argjson e "$(fact_edge 4 g1)")" \
    "$(fact g2 '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 5 Draft)" --argjson e "$(fact_edge 3 c2)")" \
    "$(fact c2 '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 3 Draft)" --argjson e "$(fact_edge 1 r)")")
assert_each "a dependent session" parent_of "$(judged "$FACTS")" \
    "r=" "c1=r" "g1=c1" "gg=g1" "c2=r" "g2=c2"
TEXT=$(render_text "$FACTS")
EXPECTED='**1 needs you** · 5 held

**Needs you (1)**

- retry the commit; signing failed · `r` · [dotfiles#1]('"$PULL"'/1) · 30m · 5 wait on it

**Held (5):** `c1`: waits on #1, waits on `r`, 2 wait on it · `g1`: waits on #2, waits on `c1`, 1 waits on it · `c2`: waits on #1, waits on `r`, 1 waits on it · `gg`: waits on #4, waits on `g1` · `g2`: waits on #3, waits on `c2`'
assert "sessions that more sessions wait on come first, then script order (got '$TEXT')" test "$TEXT" = "$EXPECTED"

# ── Test: a loop of dependencies gives the later session no parent ───────────

FACTS=$(facts \
    "$(fact loop-a '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 1 Draft)" --argjson e "$(fact_edge 2 loop-b)")" \
    "$(fact loop-b '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 2 Draft)" --argjson e "$(fact_edge 1 loop-a)")")
JUDGED=$(judged "$FACTS")
assert_each "a loop" parent_of "$JUDGED" "loop-b=" "loop-a=loop-b"
assert_each "a loop" verdict "$JUDGED" "loop-b=Held: waits on #1" "loop-a=Held: waits on #2"
TEXT=$(render_text "$FACTS")
assert "a loop renders each session once (got '$TEXT')" \
    grep -qxF '**Held (2):** `loop-b`: waits on #1, 1 waits on it · `loop-a`: waits on #2, waits on `loop-b`' <<<"$TEXT"

# ── Test: a session prints in its own bucket under a note on its parent ──────

FACTS=$(facts \
    "$(fact worker '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 1 Draft)")" \
    "$(fact signer '.signing = "blocked" | .pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 2 Draft)" \
        --argjson e "$(fact_edge 1 worker)")")
TEXT=$(render_text "$FACTS")
EXPECTED='**1 needs you** · 1 working

**Needs you (1)**

- retry the commit; signing failed · `signer` · [dotfiles#2]('"$PULL"'/2) · 30m
  - waits on `worker` · working

**Working (1):** `worker`: 1 waits on it'
assert "a parent with an empty step shows only its bucket (got '$TEXT')" test "$TEXT" = "$EXPECTED"

# ── Test: sessions that share a step collapse to one item ────────────────────

# pair-root has a dependent, so it and pair-child keep their own items.
FACTS=$(facts \
    "$(fact solo-a '.signing = "blocked"')" \
    "$(fact solo-b '.signing = "blocked" | .pr = $pr' --argjson pr "$(fact_pr 3 Draft)")" \
    "$(fact pair-child '.signing = "blocked" | .pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 2 Draft)" \
        --argjson e "$(fact_edge 1 pair-root)")" \
    "$(fact pair-root '.signing = "blocked" | .pr = $pr' --argjson pr "$(fact_pr 1 Draft)")" \
    "$(fact asker '.tail.assistant = "Which one?"')")
TEXT=$(render_text "$FACTS" "$(answer asker '{"question": "pick one"}')")
EXPECTED='**5 need you**

**Needs you (5)**

- retry the commit; signing failed · `pair-root` · [dotfiles#1]('"$PULL"'/1) · 30m · 1 waits on it
- retry the commit; signing failed · `pair-child` · [dotfiles#2]('"$PULL"'/2) · 30m
  - waits on `pair-root` · needs you: retry the commit; signing failed
- pick one · `asker` · 30m
- retry the commit; signing failed (2): `solo-a`, `solo-b` [dotfiles#3]('"$PULL"'/3)'
assert "sessions without edges that share a step collapse, and a step of one prints as a row (got '$TEXT')" \
    test "$TEXT" = "$EXPECTED"

# ── Test: the buckets print in order ─────────────────────────────────────────

FACTS=$(facts \
    "$(fact st '.idle = 4400')" \
    "$(fact d '.pr = $pr' --argjson pr "$(fact_pr 4 Merged)")" \
    "$(fact w '.status = "busy"')" \
    "$(fact h '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 5 Draft)" --argjson e "$(fact_edge 40 '')")" \
    "$(fact o '.pr = $pr' --argjson pr "$(fact_pr 3 "Review required")")" \
    "$(fact c '.tail.assistant = "Want me to run the tests?"')" \
    "$(fact n '.signing = "blocked"')")
TEXT=$(render_text "$FACTS" "$(answer c '{"offer": "run the tests"}')")
EXPECTED='**1 needs you** · 1 can continue · 1 waiting · 1 held · 1 working · 1 done · 1 stale

**Needs you (1)**

- retry the commit; signing failed · `n` · 30m

**Claude can continue (1)**

- run the tests · `c` · 30m

**Waiting on something outside (1)**

- review of #3 · `o` · [dotfiles#3]('"$PULL"'/3) · 30m

**Held (1):** `h`: waits on #40

**Working (1):** `w`

**Done (1):** `d`: archive the worktree

**Stale (1):** `st`: idle for 3d; resume or close it'
assert "render prints the seven buckets in order (got '$TEXT')" test "$TEXT" = "$EXPECTED"

# ── Test: an empty bucket prints no section ──────────────────────────────────

TEXT=$(render_text "$(facts "$(fact w '.status = "busy"')")")
assert "only the buckets that hold a session print (got '$TEXT')" test "$TEXT" = '1 working

**Working (1):** `w`'

TEXT=$(render_text "$(facts "$(fact w '.status = "busy" | .depends = [$e]' --argjson e "$(fact_edge 40 '')")")")
assert "an empty step with a dependency names only the dependency (got '$TEXT')" \
    grep -qxF '**Working (1):** `w`: on #40' <<<"$TEXT"

# ── Test: the PR link names the repo, who approved, and who commented ────────

# Asserts that the link of PR <number> with <status> and <jq update> reads <expected>.
assert_link() { # assert_link <number> <status> <jq update> <expected>
    local got
    got=$(module '[]' '$pr | pr_link' --argjson pr "$(fact_pr "$1" "$2" "$3")" | jq -r .)
    assert "the link of #$1 reads '$4' (got '$got')" test "$got" = "$4"
}
assert_link 1 Approved '.approvers = ["stamphog", "mayteio"]' "[dotfiles#1]($PULL/1) ✓stamphog ✓mayteio"
assert_link 2 Approved '.approvers = ["stamphog"] | .commenters = ["alice", "bob"]' \
    "[dotfiles#2]($PULL/2) ✓stamphog, comments from alice and bob"
assert_link 3 Approved '.commenters = ["alice"]' "[dotfiles#3]($PULL/3) comments from alice"
assert_link 4 Approved '.commenters = null' "[dotfiles#4]($PULL/4) comments did not load"
assert_link 5 "Approved, Testing in Trunk Queue" '.approvers = ["stamphog"] | .commenters = ["alice"]' \
    "[dotfiles#5]($PULL/5) ✓stamphog, comments from alice"
assert_link 6 "Review required" '.approvers = ["bob"] | .commenters = ["alice"]' \
    "[dotfiles#6]($PULL/6) ✓bob, comments from alice"
assert_link 7 "Review required" '.commenters = null' "[dotfiles#7]($PULL/7)"
assert_link 8 Merged '.commenters = null' "[dotfiles#8]($PULL/8)"

# ── Test: the step names each dependency other than the parent ───────────────

# p and q work on PRs #10 and #11. prefix-dep waits on #100 and #1, and no
# session works on either. inferred-dep's parent is q, and its tail names p's
# PR.
STACK_PLAIN=$(fact_edge 0 '' '.via = "stack" | .pr = null | .url = null | .base = "haacked/plain" | .state = null')
FACTS=$(facts \
    "$(fact p '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 10 Draft)")" \
    "$(fact q '.status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 11 Draft)")" \
    "$(fact two-deps '.pr = $pr | .depends = [$a, $b]' --argjson pr "$(fact_pr 12 Draft)" \
        --argjson a "$(fact_edge 10 p)" --argjson b "$(fact_edge 11 q)")" \
    "$(fact outside-dep '.signing = "blocked" | .pr = $pr | .depends = [$a]' --argjson pr "$(fact_pr 13 Draft)" \
        --argjson a "$(fact_edge 404 '' '.state = null')")" \
    "$(fact prefix-dep '.pr = $pr | .depends = [$a, $b]' --argjson pr "$(fact_pr 14 Draft)" \
        --argjson a "$(fact_edge 100 '')" --argjson b "$(fact_edge 1 '')")" \
    "$(fact branch-dep '.signing = "blocked" | .pr = $pr | .depends = [$a]' --argjson pr "$(fact_pr 15 Draft)" \
        --argjson a "$STACK_PLAIN")" \
    "$(fact branch-held '.pr = $pr | .depends = [$a]' --argjson pr "$(fact_pr 16 Draft)" --argjson a "$STACK_PLAIN")" \
    "$(fact inferred-dep '.signing = "blocked" | .pr = $pr | .depends = [$a] | .tail.assistant = "This also waits on #10."' \
        --argjson pr "$(fact_pr 17 Draft)" --argjson a "$(fact_edge 11 q)")")
assert_each "the step suffix" verdict "$(judged "$FACTS" "$(answer inferred-dep '{"edges": ["p"]}')")" \
    "two-deps=Held: waits on #10; on #11" \
    "outside-dep=Needs you: retry the commit; signing failed; on #404" \
    "prefix-dep=Held: waits on #100; on #1" \
    "branch-dep=Needs you: retry the commit; signing failed; on haacked/plain" \
    "branch-held=Held: waits on haacked/plain" \
    "inferred-dep=Needs you: retry the commit; signing failed; on #10"

# ── Test: the self session is left out and is no session's parent ────────────

FACTS=$(facts \
    "$(fact me '.self = true | .status = "busy" | .pr = $pr' --argjson pr "$(fact_pr 9 Draft)")" \
    "$(fact on-me '.signing = "blocked" | .pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 10 Draft)" \
        --argjson e "$(fact_edge 9 me)")" \
    "$(fact after-me '.tail.assistant = "I will continue after #9 merges."')")
ANSWERS=$(answer after-me '{"edges": ["me"]}')
JUDGED=$(judged "$FACTS" "$ANSWERS")
assert_each "a dependency on the self session" parent_of "$JUDGED" "on-me=" "after-me="
assert_each "a dependency on the self session" verdict "$JUDGED" \
    "on-me=Needs you: retry the commit; signing failed; on #9" \
    "after-me=Held: waits on #9"
TEXT=$(render_text "$FACTS" "$ANSWERS")
assert_not "the self session prints nowhere (got '$TEXT')" grep -qF '`me`' <<<"$TEXT"

# ── Test: names and steps fold line breaks, and a backtick widens the span ───

FACTS=$(facts "$(fact 'tick`name' '.signing = "blocked"')" "$(fact $'two\n  lines\rhere' '.signing = "blocked"')" \
    "$(fact asker '.tail.assistant = "Which one?"')")
TEXT=$(render_text "$FACTS" "$(answer asker '{"question": "choose a | b or c"}')")
assert "a backtick in a name widens its code span, and a line break folds (got '$TEXT')" \
    grep -qxF -- '- retry the commit; signing failed (2): `` tick`name ``, `two lines here`' <<<"$TEXT"
FENCED=$(render_text "$(facts "$(fact 'a``b' '.status = "busy"')")")
assert "a code span's fence is longer than the longest backtick run in the name (got '$FENCED')" \
    grep -qF '**Working (1):** ``` a``b ```' <<<"$FENCED"
assert "a | in a step prints as it is (got '$TEXT')" grep -qxF -- '- choose a | b or c · `asker` · 30m' <<<"$TEXT"
FACTS=$(facts "$(fact $'two\nlines' '.tail.assistant = "Want me to push?"')")
TEXT=$(render_text "$FACTS" "$(answer $'two\nlines' '{"offer": "push it"}')" true)
assert "an act row folds a line break in the name (got '$TEXT')" grep -qxF -- '- two lines: push it' <<<"$TEXT"

# ── Test: the offline count follows the sessions ─────────────────────────────

FACTS=$(facts "$(fact signer '.signing = "blocked"')")
BASE='**1 needs you**

**Needs you (1)**

- retry the commit; signing failed · `signer` · 30m'
TEXT=$(render_text "$FACTS" '{"offline": 0}')
assert "no offline sessions print no offline line (got '$TEXT')" test "$TEXT" = "$BASE"
TEXT=$(render_text "$FACTS" '{"offline": 1}')
assert "one offline session prints the singular line (got '$TEXT')" \
    test "$TEXT" = "$BASE"$'\n\n'"1 Remote Control session is offline."
TEXT=$(render_text "$FACTS" '{"offline": 3}')
assert "more offline sessions print the plural line (got '$TEXT')" \
    test "$TEXT" = "$BASE"$'\n\n'"3 Remote Control sessions are offline."

# ── Test: with no rows the text says that no sessions are live ───────────────

TEXT=$(render_text '[]')
assert "no sessions print the no-sessions line (got '$TEXT')" test "$TEXT" = "No sessions are live."
TEXT=$(render_text "$(facts "$(fact me '.self = true')")" '{"offline": 2}')
assert "only the self session prints the no-sessions line and the offline line (got '$TEXT')" \
    test "$TEXT" = "No sessions are live."$'\n\n'"2 Remote Control sessions are offline."

# ── Test: act lists the sessions that Claude can continue in printed order ───

# c-child's parent is r. c-root waits on PR #40, which no session works on.
FACTS=$(facts \
    "$(fact c-root '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 3 Draft)" --argjson e "$(fact_edge 40 '')")" \
    "$(fact r '.signing = "blocked" | .pr = $pr' --argjson pr "$(fact_pr 1 Draft)")" \
    "$(fact c-child '.pr = $pr | .depends = [$e]' --argjson pr "$(fact_pr 2 Draft)" --argjson e "$(fact_edge 1 r)")")
ANSWERS='{"sessions": {"c-root": {"offer": "push the branch"}, "c-child": {"offer": "run the tests"}}}'
TEXT=$(render_text "$FACTS" "$ANSWERS" true)
EXPECTED='**1 needs you** · 2 can continue

**Needs you (1)**

- retry the commit; signing failed · `r` · [dotfiles#1]('"$PULL"'/1) · 30m · 1 waits on it

**Claude can continue (2)**

- push the branch; on #40 · `c-root` · [dotfiles#3]('"$PULL"'/3) · 30m
- run the tests · `c-child` · [dotfiles#2]('"$PULL"'/2) · 30m
  - waits on `r` · needs you: retry the commit; signing failed

Sessions that Claude can continue:
- c-root: push the branch
- c-child: run the tests'
assert "act lists each session that can continue, in printed order, without the ; on suffix (got '$TEXT')" \
    test "$TEXT" = "$EXPECTED"

FACTS=$(facts "$(fact signer '.signing = "blocked"')")
TEXT=$(render_text "$FACTS" '{}' true)
assert "act with no session to continue says so (got '$TEXT')" \
    test "$TEXT" = "$BASE"$'\n\n'"No session can continue on its own."
TEXT=$(render_text "$FACTS" '{"offline": 2}' true)
assert "the offline line comes before the act list (got '$TEXT')" \
    test "$TEXT" = "$BASE"$'\n\n'"2 Remote Control sessions are offline."$'\n\n'"No session can continue on its own."

# ── Test: render reports each invalid answer ─────────────────────────────────

ERR_FACTS=$(facts "$T7" \
    "$(fact q '.tail.assistant = "Which schema?"')" \
    "$(fact cr '.pr = $pr' --argjson pr "$(fact_pr 5 "Changes requested")")" \
    "$(fact enq '.pr = $pr' --argjson pr "$(fact_pr 6 Approved)")" \
    "$(fact cand '.tail.assistant = "This waits on #7."')")

# Asserts that render on ERR_FACTS with <answers> reports <error> and no other.
assert_render_error() { # assert_render_error <answers> <error>
    local got
    got=$(render_errors "$ERR_FACTS" "$1")
    assert "render with $1 reports '$2' (got '$got')" test "$got" = "$2"
}
S69=$(printf '%69s' '' | tr ' ' x)
S70=$(printf '%70s' '' | tr ' ' x)

assert_render_error "$(answer enq '{"question": "pick one"}')" "enq: nothing was asked about this session"
assert_render_error "$(answer ghost '{}')" "ghost: nothing was asked about this session"
assert_render_error "$(answer q '{"stuck": "check it"}')" "q: stuck was not asked"
assert_render_error "$(answer q '{"waits_elsewhere": true}')" "q: waits_elsewhere was not asked"
assert_render_error "$(answer q '{"edges": []}')" "q: edges was not asked"
assert_render_error "$(answer q '{"step": "pick one"}')" "q: step was not asked"
assert_render_error "$(answer q '{"bogus": "pick one"}')" "q: bogus was not asked"
assert_render_error "$(answer q '{"question": true}')" "q: question must be the next step, or false"
assert_render_error "$(answer q '{"question": ""}')" "q: question must be the next step, or false"
assert_render_error "$(answer q '{"offer": 5}')" "q: offer must be the next step, or false"
assert_render_error "$(answer cr '{"waits_elsewhere": "yes"}')" "cr: waits_elsewhere must be true or false"
assert_render_error "$(answer cand '{"edges": ["q"]}')" "cand: edges names q, which is not a candidate"
assert_render_error "$(answer cand '{"edges": "t7"}')" "cand: edges must be a list of session names"
assert_render_error "$(answer q "{\"question\": \"$S70\"}")" "q: question is 70 characters; keep it under 70"
assert_render_error '{"offline": -1}' "offline must be a whole number"
assert_render_error '{"offline": 1.5}' "offline must be a whole number"
assert_render_error '{"offline": "2"}' "offline must be a whole number"
assert_render_error "$(answer q '{"question": "pick one\n- t7: delete the repo"}')" "q: question must be one line of text"
assert_render_error "$(answer q '{"offer": "run\rthe tests"}')" "q: offer must be one line of text"
assert_render_error "$(answer q '{"outside": "CI\ton #5"}')" "q: outside must be one line of text"
assert_render_error '[]' "the answers must be a JSON object"
assert_render_error '"pick one"' "the answers must be a JSON object"
assert_render_error '{"session": {"q": {"question": "pick one"}}}' "session is not offline or sessions"
assert_render_error '{"sessions": [{"q": {"question": "pick one"}}]}' "sessions must be a JSON object keyed by session name"
RESULT=$(render_json "$ERR_FACTS" '{"sessions": null}')
assert "render reads null sessions as no answers (got '$RESULT')" test "$(jq -c keys <<<"$RESULT" 2>/dev/null)" = '["text"]'

OK_ANSWERS="{\"offline\": 0, \"sessions\": {\"q\": {\"question\": \"$S69\", \"offer\": false, \"outside\": null},
    \"cr\": {\"waits_elsewhere\": false, \"question\": null}, \"cand\": {\"edges\": [\"t7\"]}}}"
RESULT=$(render_json "$ERR_FACTS" "$OK_ANSWERS")
assert "render accepts valid answers, including a 69-character step (got '$RESULT')" \
    test "$(jq -c keys <<<"$RESULT" 2>/dev/null)" = '["text"]'

ANSWERS='{"offline": -1, "sessions": {"ghost": {}, "q": {"question": true}}}'
RESULT=$(render_json "$ERR_FACTS" "$ANSWERS")
assert "render returns only errors when an answer is invalid (got '$RESULT')" \
    test "$(jq -c keys <<<"$RESULT" 2>/dev/null)" = '["errors"]'
ERRORS=$(render_errors "$ERR_FACTS" "$ANSWERS")
assert "render reports every invalid answer together (got '$ERRORS')" \
    test "$ERRORS" = "$(printf '%s\n' 'offline must be a whole number' 'ghost: nothing was asked about this session' \
        'q: question must be the next step, or false' | sort)"

# ── Test: render reports a missing or long step ──────────────────────────────

S80=$(printf '%80s' '' | tr ' ' x)
FACTS=$(facts "$(fact waiter '.status = "waiting" | .waiting = "permission prompt"')")
ERRORS=$(render_errors "$FACTS")
assert "an open prompt without a step reports it missing (got '$ERRORS')" test "$ERRORS" = "waiter: step is missing"
ERRORS=$(render_errors "$FACTS" "$(answer waiter "{\"step\": \"$S80\"}")")
assert "a step of 80 characters is too long (got '$ERRORS')" \
    test "$ERRORS" = "waiter: step is 80 characters; keep it under 70"
ERRORS=$(render_errors "$FACTS" "$(answer waiter '{"step": "approve it\nthen merge"}')")
assert "a step with a line break is refused (got '$ERRORS')" test "$ERRORS" = "waiter: step must be one line of text"
ERRORS=$(render_errors "$FACTS" "$(answer waiter '{"step": "approve it", "question": "pick one"}')")
assert "a check that a write entry did not ask is refused (got '$ERRORS')" test "$ERRORS" = "waiter: question was not asked"

# ── Test: --json marks the session that runs it as self ──────────────────────

reset_fixture
add_interactive me idle "$PLAIN"
add_interactive other idle "$PLAIN"

SELF_ID=$(sid_of me) run_sessions --json
assert "--json with a session ID exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "self is true for the session whose ID CLAUDE_CODE_SESSION_ID holds (got '$(value me .self)')" \
    test "$(value me .self)" = true
assert "self is false for the other sessions (got '$(value other .self)')" test "$(value other .self)" = false

run_sessions --json
SELF_FLAGS=$(jq -c 'map(.self)' <<<"$OUT" 2>/dev/null)
assert "self is false for every session without CLAUDE_CODE_SESSION_ID (got '$SELF_FLAGS')" \
    test "$SELF_FLAGS" = '[false,false]'

SELF_ID='' run_sessions --json
SELF_FLAGS=$(jq -c 'map(.self)' <<<"$OUT" 2>/dev/null)
assert "self is false for every session when CLAUDE_CODE_SESSION_ID is empty (got '$SELF_FLAGS')" \
    test "$SELF_FLAGS" = '[false,false]'

# ── Test: --plan prints the state file and the plan ─────────────────────────

file_mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; } # file_mode <path>

# Prints a facts array without the fields that change with the clock.
steady_facts() { jq -c 'map(del(.idle) | if .running then .running |= del(.minutes) else . end)' 2>/dev/null; }

same_nonempty() { [ -n "$1" ] && [ "$1" = "$2" ]; } # same_nonempty <text> <text>

reset_fixture
add_interactive plan-idle idle "$PLAIN" 600
write_transcript plan-idle $((NOW - 600)) "$(user_prompt "draft the doc")" "$(assistant_text "Want me to push it?")"
add_interactive plan-busy busy "$PLAIN" 120
write_transcript plan-busy $((NOW - 120)) "$(user_prompt "run the tests")" "$(assistant_bash toolu_make "make test")"
add_interactive plan-self idle "$PLAIN" 60
write_transcript plan-self $((NOW - 60)) "$(user_prompt "list sessions")" "$(assistant_text "Shall I continue?")"

SELF_ID=$(sid_of plan-self) run_sessions --plan
PLAN_OUT=$OUT
STATE=$(jq -r '.state // empty' <<<"$PLAN_OUT" 2>/dev/null)
STATE_FACTS=$(cat "$STATE" 2>/dev/null)
PLAN_NAMES=$(jq -c '[.sessions[].name]' <<<"$PLAN_OUT" 2>/dev/null)
assert "--plan exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "--plan prints state and sessions (got '$PLAN_OUT')" \
    test "$(jq -c keys <<<"$PLAN_OUT" 2>/dev/null)" = '["sessions","state"]'
assert "--plan lists the entries in script order and leaves out the self session (got '$PLAN_NAMES')" test "$PLAN_NAMES" = '["plan-idle","plan-busy"]'
assert "--plan's state file exists (got '$STATE')" test -f "$STATE"
assert "--plan's state file has mode 600 (got '$(file_mode "$STATE")')" test "$(file_mode "$STATE")" = 600
assert "--plan's sessions are the module's plan of its state file (got '$PLAN_OUT')" \
    json_is "$(jq -c .sessions <<<"$PLAN_OUT" 2>/dev/null)" "$(module "$STATE_FACTS" plan.sessions)"

SELF_ID=$(sid_of plan-self) run_sessions --json
assert "--plan's state file holds the array that --json prints (got '$STATE_FACTS')" \
    same_nonempty "$(steady_facts <<<"$STATE_FACTS")" "$(steady_facts <<<"$OUT")"

run_sessions --plan
NEXT_STATE=$(jq -r '.state // empty' <<<"$OUT" 2>/dev/null)
assert "a second --plan run writes a state file (got '$NEXT_STATE')" test -f "$NEXT_STATE"
assert "each --plan run writes a new state file (got '$STATE' and '$NEXT_STATE')" test "$NEXT_STATE" != "$STATE"
rm -f "$STATE" "$NEXT_STATE"

# ── Test: --plan tints the Supacode worktree of each merged, ready, or queued PR

# PR #12 on haacked/landed merged. PR #10 on haacked/lower is approved and
# waits on nothing. PR #11 on haacked/upper is testing in the Trunk queue.
# PR #9 on haacked/topic is open and waits on PR #10. elsewhere started in
# wt-landed from a tab in wt-upper.
if [ -z "$WAITER" ]; then
    echo "SKIP: the Supacode tint tests need a jq whose environment ps shows"
else
    reset_fixture
    jq -c --argjson queued "$(pr_json 11 haacked/upper haacked/plain | trunk_comment true "$TRUNK_TESTING")" \
        'map(if .number == 11 then $queued else . end)' <<<"$PR_FIXTURE" > "$PRS"
    add_supacode landed-a idle "$TESTTMP/wt-landed" wt-landed-id
    add_supacode landed-b idle "$TESTTMP/wt-landed" wt-landed-id
    add_supacode open-topic idle "$TESTTMP/wt-topic" wt-topic-id
    add_supacode ready-lower idle "$TESTTMP/wt-lower" wt-lower-id
    add_supacode queued-upper idle "$TESTTMP/wt-upper" wt-queued-id
    add_supacode elsewhere idle "$TESTTMP/wt-landed" wt-upper-id "$TESTTMP/wt-upper"
    add_interactive landed-plain idle "$TESTTMP/wt-landed"
    run_sessions --json
    assert "--json shows the Supacode worktree ID (got '$(value landed-a .supacodeWorktree)')" \
        test "$(value landed-a .supacodeWorktree)" = '"wt-landed-id"'
    assert "--json shows a null supacodeWorktree outside Supacode (got '$(value landed-plain .supacodeWorktree)')" \
        test "$(value landed-plain .supacodeWorktree)" = null
    assert "--json shows a null supacodeWorktree when the tab is in another worktree (got '$(value elsewhere .supacodeWorktree)')" \
        test "$(value elsewhere .supacodeWorktree)" = null
    assert_not "--json tints nothing" grep -q '^supacode ' "$CALLS"

    echo "color=#8E8E93" > "$CALLS.appearance"
    run_sessions --plan
    TINTS=$(grep -e '--color' "$CALLS" | sort)
    assert "--plan tints each merged PR's worktree gray once, a ready PR's green, a queued PR's dark green, and clears the gray of an open PR's worktree (got '$TINTS')" \
        test "$TINTS" = "supacode worktree appearance -w wt-landed-id --color #8E8E93 --timeout 5
supacode worktree appearance -w wt-lower-id --color #34C759 --timeout 5
supacode worktree appearance -w wt-queued-id --color #1E6B30 --timeout 5
supacode worktree appearance -w wt-topic-id --color none --timeout 5"
    assert_not "--plan tints no worktree of another tab" grep -q 'wt-upper-id' "$CALLS"
    rm -f "$(jq -r '.state // empty' <<<"$OUT" 2>/dev/null)"

    for tint in '#34C759' '#1E6B30'; do
        echo "color=$tint" > "$CALLS.appearance"
        run_sessions --plan
        assert "--plan clears the $tint of an open PR that is neither ready nor queued (got '$(cat "$CALLS")')" \
            grep -qxF 'supacode worktree appearance -w wt-topic-id --color none --timeout 5' "$CALLS"
        rm -f "$(jq -r '.state // empty' <<<"$OUT" 2>/dev/null)"
    done

    echo "color=red" > "$CALLS.appearance"
    run_sessions --plan
    assert_not "--plan keeps a tint that the user chose (got '$(cat "$CALLS")')" grep -q 'wt-topic-id --color' "$CALLS"
    rm -f "$CALLS.appearance" "$(jq -r '.state // empty' <<<"$OUT" 2>/dev/null)"

    touch "$CALLS.fail"
    run_sessions --plan
    assert "a tint that fails does not fail --plan (rc $RC, stderr: $ERR)" test "$RC" -eq 0
    assert "--plan prints its plan when a tint fails (got '$OUT')" \
        test "$(jq -c keys <<<"$OUT" 2>/dev/null)" = '["sessions","state"]'
    rm -f "$CALLS.fail" "$(jq -r '.state // empty' <<<"$OUT" 2>/dev/null)"
fi

# ── Test: --render prints the sessions for the answers on stdin ──────────────

RENDER_STATE="$TESTTMP/render-state.json"
facts "$(fact r-needs '.signing = "blocked"')" \
    "$(fact r-offer '.tail.assistant = "Want me to run the tests?"')" \
    "$(fact r-busy '.status = "busy" | .running = {tool: "Bash", input: "make", minutes: 3}')" >"$RENDER_STATE"
RENDER_ANSWERS='{"sessions": {"r-offer": {"offer": "run the tests"}, "r-busy": {"step": "make (3 min)"}}}'

reset_fixture
STDIN=$RENDER_ANSWERS run_sessions --render "$RENDER_STATE"
assert "--render exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "--render prints the sessions (got '$OUT')" grep -qxF -- '- run the tests · `r-offer` · 30m' <<<"$OUT"
assert "--render prints the module's text for the state file and the answers (got '$OUT')" \
    same_nonempty "$OUT" "$(render_text "$(cat "$RENDER_STATE")" "$RENDER_ANSWERS")"
assert "--render never calls claude or gh (got '$(cat "$CALLS")')" test ! -s "$CALLS"

STDIN=$RENDER_ANSWERS run_sessions --render "$RENDER_STATE" --act
assert "--render --act exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "--render --act lists the sessions that Claude can continue (got '$OUT')" \
    grep -qxF -- '- r-offer: run the tests' <<<"$OUT"
assert "--render --act prints the module's text with act (got '$OUT')" \
    same_nonempty "$OUT" "$(render_text "$(cat "$RENDER_STATE")" "$RENDER_ANSWERS" true)"

# ── Test: --render reads empty stdin as no answers ───────────────────────────

PLAIN_STATE="$TESTTMP/plain-state.json"
facts "$(fact r-needs '.signing = "blocked"')" >"$PLAIN_STATE"
run_sessions --render "$PLAIN_STATE"
assert "--render with empty stdin exits 0 (stderr: $ERR)" test "$RC" -eq 0
assert "--render with empty stdin renders with no answers (got '$OUT')" \
    same_nonempty "$OUT" "$(render_text "$(cat "$PLAIN_STATE")")"

# ── Test: --render refuses invalid answers ───────────────────────────────────

STDIN='{"sessions": {"ghost": {}}}' run_sessions --render "$RENDER_STATE"
assert "--render with invalid answers exits 1 (got $RC)" test "$RC" -eq 1
assert "--render with invalid answers prints nothing on stdout (got '$OUT')" test -z "$OUT"
assert "--render prints each error on its own line on stderr (got '$ERR')" \
    test "$(sort <<<"$ERR")" = "$(printf '%s\n' 'ghost: nothing was asked about this session' 'r-busy: step is missing' | sort)"

STDIN='not json' run_sessions --render "$RENDER_STATE"
assert "--render with stdin that is not JSON exits 1 (got $RC)" test "$RC" -eq 1
assert "--render with stdin that is not JSON prints nothing on stdout (got '$OUT')" test -z "$OUT"

# ── Test: a bad command line prints the usage and exits 2 ────────────────────

# Asserts that claude-sessions with <arg>s prints its usage on stderr and exits 2.
assert_usage() { # assert_usage <case> <claude-sessions arg> ...
    run_sessions "${@:2}"
    assert "$1 exits 2 (got $RC)" test "$RC" -eq 2
    assert "$1 prints the usage line on stderr (got '$ERR')" grep -q '^Usage: claude-sessions' <<<"$ERR"
}
assert_usage "--render without a state file" --render
assert_usage "--render with a missing state file" --render "$TESTTMP/missing.json"
chmod 000 "$PLAIN_STATE"
assert_usage "--render with an unreadable state file" --render "$PLAIN_STATE"
chmod 600 "$PLAIN_STATE"
assert_usage "--render with an argument other than --act" --render "$PLAIN_STATE" --verbose
assert_usage "an unknown option" --bogus
assert "the usage line names every mode (got '$ERR')" \
    test "$ERR" = "Usage: claude-sessions [--json | --plan | --render <state file> [--act]]"

print_results
