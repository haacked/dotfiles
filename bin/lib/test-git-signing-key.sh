#!/bin/bash
# Tests for git-signing-key's key-resolution logic: local fallback, literal
# key values, a key path that blocks on open, a live forwarded agent, and a
# forwarded agent that's gone by the time `ssh-add -L` runs.
#
# Usage: test-git-signing-key.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
BIN="$(cd "$SCRIPT_DIR/.." && pwd)/git-signing-key"

agent_pids=()
FAKE_HOME=$(cd "$(mktemp -d /tmp/t.XXXXXX)" && pwd -P)
cleanup() {
  local pid
  for pid in "${agent_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  rm -rf "$FAKE_HOME"
}
trap cleanup EXIT

set_signing_key() {
  git config --file "$FAKE_HOME/.gitconfig.local" user.localSigningKey "$1"
}

# ── Test: local signing key configured and present on disk ─────────────────
# Set through an [include], mirroring the real machine's ~/.gitconfig ->
# ~/.gitconfig.local layout, so this exercises the --includes flag
# git-signing-key depends on rather than a value git would find anyway.

KEY_FILE="$FAKE_HOME/id_test.pub"
echo "ssh-ed25519 AAAAtest test@example.com" > "$KEY_FILE"
cat > "$FAKE_HOME/.gitconfig" <<EOF
[include]
	path = $FAKE_HOME/.gitconfig.local
EOF
set_signing_key "$KEY_FILE"

out=$(run_bin)
assert "prints key:: plus the local signing key contents" \
  test "$out" = "key::$(cat "$KEY_FILE")"

# ── Test: a literal key value needs no filesystem access ───────────────────
# Pinning the key by value takes the key file out of the commit path, since
# there's nothing to open. The forwarded-agent probe still runs first, so this
# is one blocking source fewer rather than none.

LITERAL="ssh-ed25519 AAAAliteral literal@example.com"
set_signing_key "key::$LITERAL"

out=$(run_bin)
assert "passes a key:: literal through unchanged" \
  test "$out" = "key::$LITERAL"

# ── Test: a bare key literal gets the key:: prefix ─────────────────────────
# git-config(1) documents the unprefixed form as deprecated but still
# accepted, so accept it here rather than treating it as a path.

set_signing_key "$LITERAL"

out=$(run_bin)
assert "prefixes a bare key literal with key::" \
  test "$out" = "key::$LITERAL"

# ── Test: a key path that blocks on open fails fast ────────────────────────
# The regression this guards: reading the signing key blocked forever in
# open(), so every `git commit` hung with no output and no error. A FIFO with
# no writer reproduces that block deterministically. The script must give up
# and exit non-zero rather than wait.

BLOCKING="$FAKE_HOME/blocking.pub"
mkfifo "$BLOCKING"
set_signing_key "$BLOCKING"

rc=0
run_bin >/dev/null || rc=$?
assert "exits non-zero when the key path blocks on open" test "$rc" -ne 0
# 124 is run_bin's kill-on-deadline status, so this is the assertion that fails
# if the script goes back to waiting forever. Checking elapsed time instead
# would never be reached: the run would still be blocked.
assert "gives up on a blocking key path rather than hanging" test "$rc" -ne 124

set_signing_key "$KEY_FILE"

# ── Test: live forwarded agent already linked at agent.sock ────────────────

mkdir -p -m 700 "$FAKE_HOME/.ssh"
FORWARDED="$FAKE_HOME/forwarded-agent.sock"
agent_pids+=("$(start_agent "$FORWARDED")")
ssh-keygen -q -t ed25519 -N '' -f "$FAKE_HOME/forwarded_key" -C forwarded
SSH_AUTH_SOCK="$FORWARDED" ssh-add "$FAKE_HOME/forwarded_key" >/dev/null 2>&1
ln -sf "$FORWARDED" "$FAKE_HOME/.ssh/agent.sock"

out=$(run_bin)
assert "prints key:: plus the forwarded agent's key" \
  test "$out" = "key::$(cat "$FAKE_HOME/forwarded_key.pub")"

# ── Test: forwarded agent live but empty ────────────────────────────────────
# `ssh-add -L` against an agent with no loaded identities prints "The agent
# has no identities." to stdout and exits 1, a plausible real scenario
# (agent forwarded before any key was added to it). That sentence must not
# be mistaken for a key; git-signing-key must fall back to the local key.

EMPTY_FORWARDED="$FAKE_HOME/empty-forwarded.sock"
agent_pids+=("$(start_agent "$EMPTY_FORWARDED")")
ln -sf "$EMPTY_FORWARDED" "$FAKE_HOME/.ssh/agent.sock"

out=$(run_bin)
assert "falls back to the local key when the forwarded agent has no identities" \
  test "$out" = "key::$(cat "$KEY_FILE")"

# ── Test: forwarded agent that connects but never answers ──────────────────
# The hang this guards: a forwarded agent whose SSH transport stalled (laptop
# slept, network black-holed) still accepts the connection, so `ssh-add -L`
# waits forever and every `git commit` hangs with no output. Secretive is
# deliberately absent here, which is what keeps the socket adopted as
# "forwarded" and routes the probe through git-signing-key's own ssh-add
# rather than ssh-agent-sync's. It must give up and fall back to the local key.

STALLED="$FAKE_HOME/stalled.sock"
agent_pids+=("$(mkblackhole_sock "$STALLED")")
ln -sf "$STALLED" "$FAKE_HOME/.ssh/agent.sock"

rc=0
out=$(run_bin) || rc=$?
assert "falls back to the local key when the forwarded agent never answers" \
  test "$out" = "key::$(cat "$KEY_FILE")"
assert "a stalled forwarded agent doesn't hang the commit" test "$rc" -ne 124

# ── Test: forwarded agent gone by the time git-signing-key runs ────────────
# A bound-but-unlistened socket passes -S but refuses the connection
# `ssh-add` needs: the agent-died-mid-flight case. With Secretive present,
# ssh-agent-sync's no-arg probe must heal the symlink back to it, and
# git-signing-key must print the local key rather than failing outright.

SECRETIVE=$(secretive_sock "$FAKE_HOME")
mkdir -p "$(dirname "$SECRETIVE")"
mksock "$SECRETIVE"
DEAD_FORWARDED="$FAKE_HOME/dead-forwarded.sock"
mksock "$DEAD_FORWARDED"
ln -sf "$DEAD_FORWARDED" "$FAKE_HOME/.ssh/agent.sock"

out=$(run_bin)
assert "falls back to the local key when the forwarded agent is unreachable" \
  test "$out" = "key::$(cat "$KEY_FILE")"
assert "unreachable forwarded sock heals to Secretive" \
  test "$FAKE_HOME/.ssh/agent.sock" -ef "$SECRETIVE"

# ── Test: no local or forwarded key available ───────────────────────────────

rm -rf "$FAKE_HOME/.ssh"
rm -f "$KEY_FILE"

rc=0
run_bin >/dev/null || rc=$?
assert "exits non-zero when no key is found" test "$rc" -ne 0
assert "reports no key rather than hanging" test "$rc" -ne 124

# ── Results ──────────────────────────────────────────────────────────────────

print_results
