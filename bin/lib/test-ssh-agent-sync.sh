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
SECRETIVE=$(secretive_sock "$FAKE_HOME")
SOCK="$FAKE_HOME/.ssh/agent.sock"

# Resets the fake ~/.ssh and points agent.sock at the given target.
link_sock() {
  rm -rf "$FAKE_HOME/.ssh"
  mkdir -p "$FAKE_HOME/.ssh"
  ln -s "$1" "$SOCK"
}

RECEIPT="$FAKE_HOME/.ssh/agent.fwd"
STAMP="$FAKE_HOME/.ssh/agent.fwd.stalled"

# Points the adoption receipt at the given target. Call after link_sock,
# which wipes the fake ~/.ssh (receipt and stamp included) on every reset.
set_receipt() {
  ln -sf "$1" "$RECEIPT"
}

# ── Test: live forwarded socket ─────────────────────────────────────────────

mkdir -p "$(dirname "$SECRETIVE")"
mksock "$SECRETIVE"
FORWARDED="$FAKE_HOME/forwarded.sock"
mksock "$FORWARDED"

out=$(run_bin "$FORWARDED")
assert "live forwarded arg prints forwarded" test "$out" = "forwarded"
assert "symlink points at the forwarded socket" test "$SOCK" -ef "$FORWARDED"

# ── Test: no arg, sock missing, Secretive present ───────────────────────────

rm -rf "$FAKE_HOME/.ssh"

out=$(run_bin)
assert "no forwarded arg with Secretive present prints local" test "$out" = "local"
assert "symlink points at Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: dead forwarded arg with a dangling sock re-heals to local ─────────

link_sock "$FAKE_HOME/torn-down.sock"
DEAD_FORWARDED="$FAKE_HOME/dead-forwarded.sock"

out=$(run_bin "$DEAD_FORWARDED")
assert "dead forwarded arg with dangling sock prints local" test "$out" = "local"
assert "dangling sock re-heals to Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: dead forwarded arg while sock is already healthy stays local ──────
# Unlike the test above, $SOCK already points at Secretive, so a dead
# forwarded arg must not needlessly re-link or misclassify it.

out=$(run_bin "$DEAD_FORWARDED")
assert "dead forwarded arg with an already-healthy sock still prints local" test "$out" = "local"
assert "already-healthy sock is left pointing at Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: adopted sock that connects but never answers heals to local ───────
# A forwarded session whose transport stalled leaves a socket that passes -S
# and accepts connections but never replies, so the no-arg `ssh-add -l` probe
# waits forever. That probe runs from zsh's precmd and from git's signing path,
# so an unbounded one hangs the shell prompt and every signed commit alike.
# Timing out must be treated like any other unusable agent: heal to Secretive.

STALLED="$FAKE_HOME/stalled.sock"
agent_pids+=("$(mkblackhole_sock "$STALLED")")
link_sock "$STALLED"

rc=0
out=$(run_bin) || rc=$?
assert "adopted sock that never answers prints local" test "$out" = "local"
assert "stalled sock heals to Secretive" test "$SOCK" -ef "$SECRETIVE"
assert "a stalled adopted sock doesn't hang the prompt" test "$rc" -ne 124

# ── Test: nothing present ───────────────────────────────────────────────────

rm -rf "$FAKE_HOME/.ssh" "$FAKE_HOME/Library"

out=$(run_bin)
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

out=$(run_bin "$LOOPED")
assert "looped forwarded arg prints local" test "$out" = "local"
assert "looped forwarded arg leaves the symlink on Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: forwarded agent with different keys is genuinely remote ────────────

GENUINE="$FAKE_HOME/genuine.sock"
agent_pids+=("$(start_agent "$GENUINE")")
ssh-keygen -q -t ed25519 -N '' -f "$FAKE_HOME/remote_key" -C remote
SSH_AUTH_SOCK="$GENUINE" ssh-add "$FAKE_HOME/remote_key" >/dev/null 2>&1

out=$(run_bin "$GENUINE")
assert "distinct-key forwarded arg prints forwarded" test "$out" = "forwarded"
assert "symlink points at the genuine forwarded socket" test "$SOCK" -ef "$GENUINE"

# ── Test: empty forwarded agent is still adopted ─────────────────────────────
# A live forwarded agent with no identities yet offers nothing to compare
# against Secretive, so it can't be proven a loop; adopting it preserves
# the pre-loop-check behavior (git-signing-key falls back to the local key
# when the agent turns out to be empty at sign time).

EMPTY="$FAKE_HOME/empty.sock"
agent_pids+=("$(start_agent "$EMPTY")")

out=$(run_bin "$EMPTY")
assert "empty forwarded arg prints forwarded" test "$out" = "forwarded"
assert "symlink points at the empty forwarded socket" test "$SOCK" -ef "$EMPTY"

# ── Test: no arg, sock pre-linked to a stale-but-`-S`-true socket ───────────
# The reported-bug shape: a forwarded session ended but left its socket file
# behind, so the symlink target still passes -S while refusing connections.
# Non-SSH shells and launchd only ever call with no argument, so the no-arg
# path itself must probe reachability and heal back to Secretive.

STALE="$FAKE_HOME/stale-forwarded.sock"
mksock "$STALE"
link_sock "$STALE"

out=$(run_bin)
assert "no arg with stale forwarded sock prints local" test "$out" = "local"
assert "stale forwarded sock heals to Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: no arg, sock pre-linked to a live forwarded agent ─────────────────
# The probe must not evict a genuinely reachable forwarded agent.

link_sock "$GENUINE"

out=$(run_bin)
assert "no arg with live forwarded sock stays forwarded" test "$out" = "forwarded"
assert "live forwarded sock is left in place" test "$SOCK" -ef "$GENUINE"

# ── Test: no arg, sock pre-linked to a live but empty forwarded agent ───────
# ssh-add exits 1 (reachable, no identities) here, not 2 (unreachable); an
# empty agent stays adopted, matching the empty-forwarded adoption above.

link_sock "$EMPTY"

out=$(run_bin)
assert "no arg with live empty forwarded sock stays forwarded" test "$out" = "forwarded"
assert "live empty forwarded sock is left in place" test "$SOCK" -ef "$EMPTY"

# ── Test: adoption records a receipt; a rejected loop doesn't ───────────────
# The receipt is what lets no-arg callers find their way back to a forwarded
# agent later, so it must be written on every genuine adoption and never for
# a loop (re-adopting a loop would recreate the out-of-body failure).

link_sock "$SECRETIVE"

out=$(run_bin "$LOOPED")
assert "a rejected loop leaves no receipt" test ! -e "$RECEIPT"

echo 99 > "$STAMP"
out=$(run_bin "$GENUINE")
assert "adoption prints forwarded" test "$out" = "forwarded"
assert "adoption records the receipt" test "$RECEIPT" -ef "$GENUINE"
assert "adoption clears a leftover stall stamp" test ! -e "$STAMP"

# ── Test: a newer push overwrites the receipt ────────────────────────────────
# With two concurrent forwarded sessions, the most recent interactive login
# wins: the receipt tracks exactly one socket, the last one a human chose.

out=$(run_bin "$EMPTY")
assert "a newer push repoints the sock" test "$SOCK" -ef "$EMPTY"
assert "a newer push overwrites the receipt" test "$RECEIPT" -ef "$EMPTY"

# ── Test: no arg, sock on Secretive, receipt names a live agent ─────────────
# The motivating case: the sock healed to local (client slept, probe timed
# out) and the client is back. No-arg callers — tmux panes, launchd, git's
# signing path — must be able to re-adopt from the receipt alone.

link_sock "$SECRETIVE"
set_receipt "$GENUINE"

out=$(run_bin)
assert "re-adopt from a live receipt prints forwarded" test "$out" = "forwarded"
assert "sock links directly at the receipt's target" test "$(readlink "$SOCK")" = "$GENUINE"
assert "receipt survives re-adoption" test "$RECEIPT" -ef "$GENUINE"

# ── Test: receipt whose socket refuses the connection is deleted ────────────
# Connection-refused means the sshd session is gone for good; a fresh session
# mints a fresh socket name and pushes it, so the receipt has nothing left to
# offer and must not be re-probed forever.

REFUSED="$FAKE_HOME/refused.sock"
mksock "$REFUSED"
link_sock "$SECRETIVE"
set_receipt "$REFUSED"

out=$(run_bin)
assert "refused receipt stays local" test "$out" = "local"
assert "conclusively dead receipt is deleted" test ! -e "$RECEIPT"
assert "no stall stamp for a refused receipt" test ! -e "$STAMP"

# ── Test: dangling receipt is deleted ────────────────────────────────────────

link_sock "$SECRETIVE"
set_receipt "$FAKE_HOME/never-was.sock"

out=$(run_bin)
assert "dangling receipt stays local" test "$out" = "local"
assert "dangling receipt is deleted" test ! -e "$RECEIPT"

# ── Test: receipt that loops back to the local agent is cleared ─────────────
# The loop check applies to re-adoption exactly as it does to a push: a
# receipt offering Secretive's own key list must resolve local and be
# dropped, not adopted.

link_sock "$SECRETIVE"
set_receipt "$LOOPED"

out=$(run_bin)
assert "looped receipt resolves local" test "$out" = "local"
assert "looped receipt is cleared, not adopted" test ! -e "$RECEIPT"
assert "looped receipt leaves the sock on Secretive" test "$SOCK" -ef "$SECRETIVE"

# ── Test: sleeping receipt is kept, then re-adopted once it answers ─────────
# A receipt target that accepts but never answers is a sleeping client, not a
# dead one. The probe must stay bounded, the receipt must survive, and the
# stall stamp must defer the next probe until the minute-long retry window
# passes (forced here by backdating the stamp) — then the revived socket
# (same path, as after a lid-close/lid-open) is re-adopted.

ASLEEP="$FAKE_HOME/asleep.sock"
asleep_pid=$(mkblackhole_sock "$ASLEEP")
agent_pids+=("$asleep_pid")
link_sock "$SECRETIVE"
set_receipt "$ASLEEP"

rc=0
out=$(run_bin) || rc=$?
assert "sleeping receipt stays local" test "$out" = "local"
assert "the receipt probe is bounded, not hung" test "$rc" -ne 124
assert "sleeping receipt is kept" test -L "$RECEIPT"
assert "a stall stamp is written" test -e "$STAMP"

kill "$asleep_pid" 2>/dev/null || true
rm -f "$ASLEEP"
agent_pids+=("$(start_agent "$ASLEEP")")
SSH_AUTH_SOCK="$ASLEEP" ssh-add "$FAKE_HOME/remote_key" >/dev/null 2>&1

out=$(run_bin)
assert "a fresh stall stamp defers the next probe" test "$out" = "local"

echo 1 > "$STAMP"
out=$(run_bin)
assert "expired backoff re-adopts the revived socket" test "$out" = "forwarded"
assert "sock points at the revived socket" test "$SOCK" -ef "$ASLEEP"
assert "re-adoption clears the stall stamp" test ! -e "$STAMP"

# ── Test: stalled sock and receipt naming the same target probe once ─────────
# When the adopted sock times out and the receipt points at the same socket,
# the verdict is shared instead of probing the same blackhole twice: one 2s
# stall, not two, paid by whichever prompt or commit ran the sync.

ASLEEP2="$FAKE_HOME/asleep2.sock"
agent_pids+=("$(mkblackhole_sock "$ASLEEP2")")
link_sock "$ASLEEP2"
set_receipt "$ASLEEP2"

start=$SECONDS
rc=0
out=$(run_bin) || rc=$?
assert "stalled sock with matching receipt heals local" test "$out" = "local"
assert "the shared verdict stays bounded" test "$rc" -ne 124
assert "the shared verdict avoids a second probe" test $((SECONDS - start)) -lt 4
assert "receipt is kept after the shared verdict" test -L "$RECEIPT"
assert "the shared verdict writes the stall stamp" test -e "$STAMP"

# ── Test: --local clears the receipt and pins Secretive ─────────────────────
# The escape hatch for a forgotten-but-live remote session that keeps winning
# re-adoption: pin local, drop the receipt, and print the resolved mode.

link_sock "$GENUINE"
set_receipt "$GENUINE"
echo 99 > "$STAMP"

out=$(run_bin --local)
assert "--local prints local" test "$out" = "local"
assert "--local pins the sock to Secretive" test "$SOCK" -ef "$SECRETIVE"
assert "--local clears the receipt" test ! -e "$RECEIPT"
assert "--local clears the stall stamp" test ! -e "$STAMP"

rm -rf "$FAKE_HOME/.ssh" "$FAKE_HOME/Library"

rc=0
out=$(run_bin --local) || rc=$?
assert "--local with nothing present prints none" test "$out" = "none"
assert "--local with nothing present exits zero" test "$rc" -eq 0

# ── Test: adoption prunes old dead sshd-minted leftovers ────────────────────
# sshd doesn't always get to clean up its per-session sockets. A push removes
# conclusively dead (connection-refused) s.*.sshd.* files over an hour old —
# and nothing else: s.*.agent.* belongs to local ssh-agent instances that may
# be live, and fresh sshd sockets may belong to a session still coming up.

AGENT_DIR="$FAKE_HOME/.ssh/agent"
mkdir -p "$AGENT_DIR"
mksock "$AGENT_DIR/s.aaaa.sshd.1111"
mksock "$AGENT_DIR/s.bbbb.agent.2222"
mksock "$AGENT_DIR/s.cccc.sshd.3333"
touch -t 202601010000 "$AGENT_DIR/s.aaaa.sshd.1111" "$AGENT_DIR/s.bbbb.agent.2222"

out=$(run_bin "$GENUINE")
assert "push with leftovers still adopts" test "$out" = "forwarded"
assert "an old dead sshd-minted socket is pruned" test ! -e "$AGENT_DIR/s.aaaa.sshd.1111"
assert "ssh-agent's own sockets are never pruned" test -e "$AGENT_DIR/s.bbbb.agent.2222"
assert "fresh sshd sockets are left alone" test -e "$AGENT_DIR/s.cccc.sshd.3333"

# ── Results ──────────────────────────────────────────────────────────────────

print_results
