#!/bin/bash
# Tests for the local/forwarded/none classification in ssh-agent-sync.
#
# Usage: test-ssh-agent-sync.sh
#
# Builds a throwaway HOME with fake Secretive/forwarded sockets (real
# AF_UNIX binds, since -S only recognizes actual sockets; real ssh-agents
# where the loop detection needs comparable key lists) and exercises the
# script's healing and classification logic against it.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
BIN="$(cd "$SCRIPT_DIR/.." && pwd)/ssh-agent-sync"

# Resolve through symlinks (macOS /var -> /private/var) so `-ef` comparisons
# against paths built from $HOME match what the script itself resolves. Kept
# short and rooted at /tmp rather than the default $TMPDIR: appending the
# hardcoded Secretive container path can otherwise exceed macOS's ~104-byte
# AF_UNIX path limit.
FAKE_HOME=$(cd "$(mktemp -d /tmp/t.XXXXXX)" && pwd -P)
agent_pids=()
cleanup() {
  local pid
  for pid in "${agent_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null || true
  done
  rm -rf "$FAKE_HOME"
}
trap cleanup EXIT
SECRETIVE="$FAKE_HOME/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
SOCK="$FAKE_HOME/.ssh/agent.sock"

# ── Test: live forwarded socket ─────────────────────────────────────────────

mkdir -p "$(dirname "$SECRETIVE")"
mksock "$SECRETIVE"
FORWARDED="$FAKE_HOME/forwarded.sock"
mksock "$FORWARDED"

out=$(HOME="$FAKE_HOME" "$BIN" "$FORWARDED")
assert "live forwarded arg prints forwarded" test "$out" = "forwarded"
assert "symlink points at the forwarded socket" test "$SOCK" -ef "$FORWARDED"

# ── Test: no arg, sock missing, Secretive present ───────────────────────────

rm -rf "$FAKE_HOME/.ssh"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "no forwarded arg with Secretive present prints local" test "$out" = "local"
assert "symlink points at Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: dead forwarded arg with a dangling sock re-heals to local ─────────

rm -rf "$FAKE_HOME/.ssh"
mkdir -p "$FAKE_HOME/.ssh"
ln -s "$FAKE_HOME/torn-down.sock" "$SOCK"
DEAD_FORWARDED="$FAKE_HOME/dead-forwarded.sock"

out=$(HOME="$FAKE_HOME" "$BIN" "$DEAD_FORWARDED")
assert "dead forwarded arg with dangling sock prints local" test "$out" = "local"
assert "dangling sock re-heals to Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: dead forwarded arg while sock is already healthy stays local ──────
# Proves the elif [[ ! -S "$sock" ]] guard is a no-op here: unlike the test
# above, $SOCK already points at Secretive, so a dead forwarded arg must not
# needlessly re-link or misclassify it.

out=$(HOME="$FAKE_HOME" "$BIN" "$DEAD_FORWARDED")
assert "dead forwarded arg with an already-healthy sock still prints local" test "$out" = "local"
assert "already-healthy sock is left pointing at Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: nothing present ───────────────────────────────────────────────────

rm -rf "$FAKE_HOME/.ssh" "$FAKE_HOME/Library"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "nothing present prints none" test "$out" = "none"
assert "no symlink is created" test ! -e "$SOCK"

# ── Test: forwarded socket that loops back to the local agent ───────────────
# An `ssh macbook` run on the Mac itself forwards the Mac's own agent, so
# the "forwarded" socket offers exactly the same keys as Secretive. It must
# be classified as local, not adopted: adopting it would route signing
# approvals to a machine nobody is sitting at. Real agents both loaded with
# the same key stand in for the loop.

mkdir -p "$(dirname "$SECRETIVE")"
agent_pids+=("$(start_agent "$SECRETIVE")")
ssh-keygen -q -t ed25519 -N '' -f "$FAKE_HOME/shared_key" -C shared
SSH_AUTH_SOCK="$SECRETIVE" ssh-add "$FAKE_HOME/shared_key" >/dev/null 2>&1

LOOPED="$FAKE_HOME/looped.sock"
agent_pids+=("$(start_agent "$LOOPED")")
SSH_AUTH_SOCK="$LOOPED" ssh-add "$FAKE_HOME/shared_key" >/dev/null 2>&1

out=$(HOME="$FAKE_HOME" "$BIN" "$LOOPED")
assert "looped forwarded arg prints local" test "$out" = "local"
assert "looped forwarded arg leaves the symlink on Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: forwarded agent with different keys is genuinely remote ────────────

GENUINE="$FAKE_HOME/genuine.sock"
agent_pids+=("$(start_agent "$GENUINE")")
ssh-keygen -q -t ed25519 -N '' -f "$FAKE_HOME/remote_key" -C remote
SSH_AUTH_SOCK="$GENUINE" ssh-add "$FAKE_HOME/remote_key" >/dev/null 2>&1

out=$(HOME="$FAKE_HOME" "$BIN" "$GENUINE")
assert "distinct-key forwarded arg prints forwarded" test "$out" = "forwarded"
assert "symlink points at the genuine forwarded socket" test "$SOCK" -ef "$GENUINE"

# ── Test: empty forwarded agent is still adopted ─────────────────────────────
# A live forwarded agent with no identities yet offers nothing to compare
# against Secretive, so it can't be proven a loop; adopting it preserves
# the pre-loop-check behavior (git-signing-key falls back to the local key
# when the agent turns out to be empty at sign time).

EMPTY="$FAKE_HOME/empty.sock"
agent_pids+=("$(start_agent "$EMPTY")")

out=$(HOME="$FAKE_HOME" "$BIN" "$EMPTY")
assert "empty forwarded arg prints forwarded" test "$out" = "forwarded"
assert "symlink points at the empty forwarded socket" test "$SOCK" -ef "$EMPTY"

# ── Test: no arg, sock pre-linked to a stale-but-`-S`-true socket ───────────
# The reported-bug shape: a forwarded session ended but left its socket file
# behind, so the symlink target still passes -S while refusing connections.
# Non-SSH shells and launchd only ever call with no argument, so the no-arg
# path itself must probe reachability and heal back to Secretive.

rm -rf "$FAKE_HOME/.ssh"
mkdir -p "$FAKE_HOME/.ssh"
STALE="$FAKE_HOME/stale-forwarded.sock"
mksock "$STALE"
ln -s "$STALE" "$SOCK"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "no arg with stale forwarded sock prints local" test "$out" = "local"
assert "stale forwarded sock heals to Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: no arg, sock pre-linked to a live forwarded agent ─────────────────
# The probe must not evict a genuinely reachable forwarded agent.

rm -rf "$FAKE_HOME/.ssh"
mkdir -p "$FAKE_HOME/.ssh"
ln -s "$GENUINE" "$SOCK"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "no arg with live forwarded sock stays forwarded" test "$out" = "forwarded"
assert "live forwarded sock is left in place" test "$SOCK" -ef "$GENUINE"

# ── Test: no arg, sock pre-linked to a live but empty forwarded agent ───────
# ssh-add exits 1 (reachable, no identities) here, not 2 (unreachable); an
# empty agent stays adopted, matching the empty-forwarded adoption above.

rm -rf "$FAKE_HOME/.ssh"
mkdir -p "$FAKE_HOME/.ssh"
ln -s "$EMPTY" "$SOCK"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "no arg with live empty forwarded sock stays forwarded" test "$out" = "forwarded"
assert "live empty forwarded sock is left in place" test "$SOCK" -ef "$EMPTY"

# ── Results ──────────────────────────────────────────────────────────────────

print_results
