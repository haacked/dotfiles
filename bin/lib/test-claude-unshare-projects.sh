#!/bin/bash
# Tests for bin/claude-unshare-projects, which replaces each ~/.claude-*/projects symlink into
# ~/.claude/projects with a clone of that folder. Stubs stand in for sb, launchctl, and ps, so the tests
# never touch the real Switchboard service, launchd jobs, or processes.
#
# Usage: test-claude-unshare-projects.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../claude-unshare-projects"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT
TESTTMP=$(cd "$TESTTMP" && pwd -P)
STUBS="$TESTTMP/stubs"
mkdir -p "$STUBS"

# sb: $STUBS/sessions holds one "<id> <live>" line per session.
cat >"$STUBS/sb" <<'STUB'
#!/bin/bash
echo "sb $*" >>"$STUB_LOG"
case "$1" in
  ls) awk 'BEGIN { printf "[" } { printf "%s{\"id\":\"%s\",\"live\":%s}", (NR > 1 ? "," : ""), $1, $2 } END { print "]" }' "$STUB_STATE/sessions" ;;
  stop) sed "s/^$2 true$/$2 false/" "$STUB_STATE/sessions" >"$STUB_STATE/sessions.tmp"
    mv "$STUB_STATE/sessions.tmp" "$STUB_STATE/sessions" ;;
esac
STUB

# launchctl: $STUBS/loaded holds one loaded label per line.
cat >"$STUBS/launchctl" <<'STUB'
#!/bin/bash
echo "launchctl $*" >>"$STUB_LOG"
case "$1" in
  print) grep -qxF "${2##*/}" "$STUB_STATE/loaded" ;;
  bootout) grep -vxF "${2##*/}" "$STUB_STATE/loaded" >"$STUB_STATE/loaded.tmp" || true
    mv "$STUB_STATE/loaded.tmp" "$STUB_STATE/loaded" ;;
  bootstrap) label=$(basename "$3" .plist); echo "$label" >>"$STUB_STATE/loaded" ;;
esac
STUB

# ps: when $STUB_STATE/claude-env exists, one claude process runs with that CLAUDE_CONFIG_DIR. When
# $STUB_STATE/exits-after holds N, that claude exits after N process listings.
cat >"$STUBS/ps" <<'STUB'
#!/bin/bash
[ -f "$STUB_STATE/claude-env" ] || exit 0
if [ -f "$STUB_STATE/exits-after" ] && [[ "$*" == *comm=* ]]; then
  left=$(cat "$STUB_STATE/exits-after")
  if [ "$left" -le 0 ]; then rm -f "$STUB_STATE/claude-env"; exit 0; fi
  echo $((left - 1)) >"$STUB_STATE/exits-after"
fi
case "$*" in
  *comm=*) echo "4242 claude" ;;
  *-p\ 4242*) echo "claude --resume x PATH=/bin CLAUDE_CONFIG_DIR=$(cat "$STUB_STATE/claude-env")" ;;
esac
STUB
# claude: records `claude daemon stop` with the account it runs under.
cat >"$STUBS/claude" <<'STUB'
#!/bin/bash
echo "claude $* ($CLAUDE_CONFIG_DIR)" >>"$STUB_LOG"
STUB
chmod +x "$STUBS"/*

setup() {
  FAKE_HOME="$TESTTMP/home-$1"
  rm -rf "$FAKE_HOME"
  local shared="$FAKE_HOME/.claude/projects"
  mkdir -p "$shared/-repo/memory" "$shared/-repo/abc/tool-results" "$FAKE_HOME/.claude-prompts"
  echo '{"type":"user"}' >"$shared/-repo/abc.jsonl"
  echo "# Memory" >"$shared/-repo/memory/MEMORY.md"
  echo "result" >"$shared/-repo/abc/tool-results/x.txt"
  for account in personal max; do
    mkdir -p "$FAKE_HOME/.claude-$account"
    ln -s "$shared" "$FAKE_HOME/.claude-$account/projects"
  done
  mkdir -p "$FAKE_HOME/.claude-own/projects/-mine"
  STUB_STATE="$TESTTMP/state-$1"
  rm -rf "$STUB_STATE"
  mkdir -p "$STUB_STATE"
  printf 'one true\ntwo false\nthree true\n' >"$STUB_STATE/sessions"
  printf 'com.haacked.switchboard.sbd\ncom.haacked.standup\n' >"$STUB_STATE/loaded"
  STUB_LOG="$STUB_STATE/log"
  : >"$STUB_LOG"
}

run_script() {
  env -u CLAUDECODE -u SB_SESSION_ID HOME="$FAKE_HOME" PATH="$STUBS:$PATH" STUB_STATE="$STUB_STATE" \
    STUB_LOG="$STUB_LOG" SB="$STUBS/sb" LAUNCHCTL="$STUBS/launchctl" LAUNCH_AGENTS="$FAKE_HOME/agents" \
    CLAUDE="$STUBS/claude" CP_CLONE="cp -Rp" CLAUDE_JOB_LABELS="com.haacked.standup com.haacked.triage-daily" STOP_TIMEOUT=4 \
    EXIT_TIMEOUT=4 "$BIN" "$@"
}

is_own_folder() { [ -d "$1" ] && [ ! -L "$1" ]; }
logged() { grep -qxF "$1" "$STUB_LOG"; }

echo "# A dry run lists the accounts and changes nothing"
setup dry
out=$(run_script --dry-run 2>&1)
assert "names the personal account" grep -qF "$FAKE_HOME/.claude-personal" <<<"$out"
assert "names the max account" grep -qF "$FAKE_HOME/.claude-max" <<<"$out"
assert_not "skips an account with its own projects folder" grep -qF ".claude-own" <<<"$out"
assert "leaves the personal link" test -L "$FAKE_HOME/.claude-personal/projects"
assert_not "stops nothing" grep -qE "stop|bootout" "$STUB_LOG"

echo "# A run clones the shared folder into each linked account and restarts what it stopped"
setup run
run_script --yes >/dev/null 2>&1
for account in personal max; do
  dir="$FAKE_HOME/.claude-$account/projects"
  assert "$account has its own folder" is_own_folder "$dir"
  check_eq "$account has the transcript" "$(cat "$dir/-repo/abc.jsonl")" '{"type":"user"}'
  check_eq "$account has the memory" "$(cat "$dir/-repo/memory/MEMORY.md")" "# Memory"
  check_eq "$account has the tool result" "$(cat "$dir/-repo/abc/tool-results/x.txt")" "result"
  assert_not "$account has no leftover link" test -e "$FAKE_HOME/.claude-$account/projects.link-old"
done
assert "leaves the account with its own folder alone" test -d "$FAKE_HOME/.claude-own/projects/-mine"
assert_not "gives the prompts account no projects folder" test -e "$FAKE_HOME/.claude-prompts/projects"
assert "stops the live session one" logged "sb stop one"
assert "stops the live session three" logged "sb stop three"
assert_not "leaves the stopped session two alone" logged "sb stop two"
assert "stops sbd" logged "launchctl bootout gui/$(id -u)/com.haacked.switchboard.sbd"
assert "pauses the loaded job" logged "launchctl bootout gui/$(id -u)/com.haacked.standup"
assert_not "never stops an unloaded job" logged "launchctl bootout gui/$(id -u)/com.haacked.triage-daily"
assert_not "never starts an unloaded job" grep -qxF com.haacked.triage-daily "$STUB_STATE/loaded"
assert "starts sbd again" grep -qxF com.haacked.switchboard.sbd "$STUB_STATE/loaded"
assert "starts the job again" grep -qxF com.haacked.standup "$STUB_STATE/loaded"
assert "stops the personal daemon" logged "claude daemon stop --any ($FAKE_HOME/.claude-personal)"
assert "stops the max daemon" logged "claude daemon stop --any ($FAKE_HOME/.claude-max)"
assert_not "leaves the daemon of an unchanged account alone" grep -qF ".claude-own)" "$STUB_LOG"
check_eq "the shared folder keeps its transcript" "$(cat "$FAKE_HOME/.claude/projects/-repo/abc.jsonl")" '{"type":"user"}'

echo "# A second run finds nothing to do and stops nothing"
: >"$STUB_LOG"
out=$(run_script --yes 2>&1)
assert "says there is nothing to do" grep -qF "Nothing to do" <<<"$out"
assert_not "stops nothing" grep -qE "stop|bootout" "$STUB_LOG"

echo "# A claude still running on an account blocks the swap, and sbd and the jobs start again"
setup busy
echo "$FAKE_HOME/.claude-max" >"$STUB_STATE/claude-env"
rc=0
out=$(run_script --yes 2>&1) || rc=$?
check_eq "exits with an error" "$rc" 1
assert "names the pid" grep -qF "pid 4242" <<<"$out"
assert "keeps the personal link" test -L "$FAKE_HOME/.claude-personal/projects"
assert "keeps the max link" test -L "$FAKE_HOME/.claude-max/projects"
assert "starts sbd again" grep -qxF com.haacked.switchboard.sbd "$STUB_STATE/loaded"
assert "starts the job again" grep -qxF com.haacked.standup "$STUB_STATE/loaded"

echo "# A claude that exits while the script waits doesn't block the swap"
setup exiting
echo "$FAKE_HOME/.claude-max" >"$STUB_STATE/claude-env"
echo 1 >"$STUB_STATE/exits-after"
run_script --yes >/dev/null 2>&1
assert "swaps max" is_own_folder "$FAKE_HOME/.claude-max/projects"

echo "# A claude on an account the script doesn't change doesn't block it"
setup elsewhere
echo "$FAKE_HOME/.claude-own" >"$STUB_STATE/claude-env"
run_script --yes >/dev/null 2>&1
assert "swaps personal" is_own_folder "$FAKE_HOME/.claude-personal/projects"

echo "# A session that doesn't stop blocks the swap"
setup stuck
cat >"$STUBS/sb-stuck" <<'STUB'
#!/bin/bash
echo "sb $*" >>"$STUB_LOG"
[ "$1" = ls ] && echo '[{"id":"one","live":true}]'
exit 0
STUB
chmod +x "$STUBS/sb-stuck"
rc=0
out=$(env -u CLAUDECODE -u SB_SESSION_ID HOME="$FAKE_HOME" PATH="$STUBS:$PATH" STUB_STATE="$STUB_STATE" \
  STUB_LOG="$STUB_LOG" SB="$STUBS/sb-stuck" LAUNCHCTL="$STUBS/launchctl" LAUNCH_AGENTS="$FAKE_HOME/agents" \
  CLAUDE_JOB_LABELS="com.haacked.standup" STOP_TIMEOUT=2 "$BIN" --yes 2>&1) || rc=$?
check_eq "exits with an error" "$rc" 1
assert "names the session" grep -qF "didn't stop" <<<"$out"
assert "keeps the personal link" test -L "$FAKE_HOME/.claude-personal/projects"
assert_not "never stops sbd" logged "launchctl bootout gui/$(id -u)/com.haacked.switchboard.sbd"
assert "starts the job again" grep -qxF com.haacked.standup "$STUB_STATE/loaded"

echo "# An interrupted swap finishes on the next run"
setup interrupted
mv "$FAKE_HOME/.claude-max/projects" "$FAKE_HOME/.claude-max/projects.link-old"
mkdir -p "$FAKE_HOME/.claude-max/projects.new/partial"
run_script --yes >/dev/null 2>&1
assert "max has its own folder" is_own_folder "$FAKE_HOME/.claude-max/projects"
check_eq "max has the transcript" "$(cat "$FAKE_HOME/.claude-max/projects/-repo/abc.jsonl")" '{"type":"user"}'
assert_not "max drops the partial clone" test -e "$FAKE_HOME/.claude-max/projects/partial"
assert_not "max has no leftover link" test -e "$FAKE_HOME/.claude-max/projects.link-old"

echo "# It refuses to run inside a claude session"
setup inside
rc=0
out=$(env CLAUDECODE=1 HOME="$FAKE_HOME" SB="$STUBS/sb" LAUNCHCTL="$STUBS/launchctl" "$BIN" --yes 2>&1) || rc=$?
check_eq "exits with an error" "$rc" 1
assert "says to use a plain terminal" grep -qF "plain terminal" <<<"$out"
assert "keeps the personal link" test -L "$FAKE_HOME/.claude-personal/projects"
assert_not "stops nothing" grep -qE "stop|bootout" "$STUB_LOG"

print_results
