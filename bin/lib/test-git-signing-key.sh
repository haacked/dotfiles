#!/bin/bash
# Tests for git-signing-key's key-resolution logic: local fallback, a live
# forwarded agent, and a forwarded agent that's gone by the time `ssh-add
# -L` runs.
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

# ── Test: local signing key configured and present on disk ─────────────────

KEY_FILE="$FAKE_HOME/id_test.pub"
echo "ssh-ed25519 AAAAtest test@example.com" > "$KEY_FILE"
HOME="$FAKE_HOME" git config --global user.localSigningKey "$KEY_FILE"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "prints key:: plus the local signing key contents" \
  test "$out" = "key::$(cat "$KEY_FILE")"

# ── Test: live forwarded agent already linked at agent.sock ────────────────

mkdir -p -m 700 "$FAKE_HOME/.ssh"
FORWARDED="$FAKE_HOME/forwarded-agent.sock"
agent_pids+=("$(start_agent "$FORWARDED")")
ssh-keygen -q -t ed25519 -N '' -f "$FAKE_HOME/forwarded_key" -C forwarded
SSH_AUTH_SOCK="$FORWARDED" ssh-add "$FAKE_HOME/forwarded_key" >/dev/null 2>&1
ln -sf "$FORWARDED" "$FAKE_HOME/.ssh/agent.sock"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "prints key:: plus the forwarded agent's key" \
  test "$out" = "key::$(cat "$FAKE_HOME/forwarded_key.pub")"

# ── Test: forwarded agent live but empty ────────────────────────────────────
# `ssh-add -L` against an agent with no loaded identities prints "The agent
# has no identities." to stdout and exits 1 — a plausible real scenario
# (agent forwarded before any key was added to it). That sentence must not
# be mistaken for a key; git-signing-key must fall back to the local key.

EMPTY_FORWARDED="$FAKE_HOME/empty-forwarded.sock"
agent_pids+=("$(start_agent "$EMPTY_FORWARDED")")
ln -sf "$EMPTY_FORWARDED" "$FAKE_HOME/.ssh/agent.sock"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "falls back to the local key when the forwarded agent has no identities" \
  test "$out" = "key::$(cat "$KEY_FILE")"

# ── Test: forwarded agent gone by the time ssh-add -L runs ─────────────────
# A bound-but-unlistened socket passes the -S liveness check ssh-agent-sync
# uses to leave the link alone, but refuses the connection `ssh-add -L`
# needs — the agent-died-mid-flight case. git-signing-key must fall back to
# the local key rather than failing outright.

DEAD_FORWARDED="$FAKE_HOME/dead-forwarded.sock"
mksock "$DEAD_FORWARDED"
ln -sf "$DEAD_FORWARDED" "$FAKE_HOME/.ssh/agent.sock"

out=$(HOME="$FAKE_HOME" "$BIN")
assert "falls back to the local key when the forwarded agent is unreachable" \
  test "$out" = "key::$(cat "$KEY_FILE")"

# ── Test: no local or forwarded key available ───────────────────────────────

rm -rf "$FAKE_HOME/.ssh"
rm -f "$KEY_FILE"

rc=0
HOME="$FAKE_HOME" "$BIN" >/dev/null 2>/dev/null || rc=$?
assert "exits non-zero when no key is found" test "$rc" -ne 0

# ── Results ──────────────────────────────────────────────────────────────────

print_results
