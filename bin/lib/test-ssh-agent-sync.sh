#!/bin/bash
# Tests for the local/forwarded/none classification in ssh-agent-sync.
#
# Usage: test-ssh-agent-sync.sh
#
# Builds a throwaway HOME with fake Secretive/forwarded sockets (real
# AF_UNIX binds, since -S only recognizes actual sockets) and exercises the
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
trap 'rm -rf "$FAKE_HOME"' EXIT
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

# ── Results ──────────────────────────────────────────────────────────────────

print_results
