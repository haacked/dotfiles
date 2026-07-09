#!/bin/bash
# End-to-end integration test: a real `git commit -S` against this
# worktree's gpg.ssh.defaultKeyCommand wiring (bin/git-signing-key +
# bin/ssh-agent-sync), covering the plan's Stage 4 scenarios in isolated
# fake HOMEs. Never touches the live machine's ~/.gitconfig or ~/.ssh.
#
# SSH_AUTH_SOCK is exported once per test to the *stable symlink path*
# ($home/.ssh/agent.sock) and never changed again, mirroring how a real
# shell/launchd only ever exports that fixed path. What changes between
# scenarios is the symlink's target on disk, healed by ssh-agent-sync
# inside git-signing-key immediately before ssh-keygen (a sibling process
# git spawns afterward) connects through it.
#
# Usage: test-git-signing-integration.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
GIT_SIGNING_KEY="$REPO_ROOT/bin/git-signing-key"

agent_pids=()
homes=()
cleanup() {
  local pid
  for pid in "${agent_pids[@]:-}"; do
    [[ -n "$pid" ]] && kill "$pid" 2>/dev/null
  done
  local h
  for h in "${homes[@]:-}"; do
    rm -rf "$h"
  done
}
trap cleanup EXIT

# Rooted at /tmp (not $TMPDIR) with a short prefix: the Secretive-style
# AF_UNIX path built under it can otherwise exceed macOS's ~104-byte socket
# path limit.
new_home() {
  local h
  h=$(cd "$(mktemp -d /tmp/t.XXXXXX)" && pwd -P)
  homes+=("$h")
  printf '%s\n' "$h"
}

# A gitconfig wired the same way as git/gitconfig.symlink, pointed at this
# worktree's git-signing-key so the test exercises uncommitted changes.
# Includes ~/.gitconfig.local the same way the real machine does, so
# setup_local_agent's use of it below exercises the --includes flag
# git-signing-key depends on rather than a value git would find anyway.
write_gitconfig() {
  local home="$1"
  cat > "$home/.gitconfig" <<EOF
[include]
	path = $home/.gitconfig.local
[user]
	name = Test User
	email = test@example.com
[gpg]
	format = ssh
[gpg "ssh"]
	program = /usr/bin/ssh-keygen
	defaultKeyCommand = $GIT_SIGNING_KEY
[commit]
	gpgsign = true
[init]
	defaultBranch = main
EOF
}

# Starts a fake "Secretive" agent at the real expected socket path under
# $1 and configures it as user.localSigningKey via a freshly generated key.
setup_local_agent() {
  local home="$1"
  local secretive="$home/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
  mkdir -p "$(dirname "$secretive")"
  agent_pids+=("$(start_agent "$secretive")")
  ssh-keygen -q -t ed25519 -N '' -f "$home/local_key" -C local
  SSH_AUTH_SOCK="$secretive" ssh-add "$home/local_key" >/dev/null 2>&1
  git config --file "$home/.gitconfig.local" user.localSigningKey "$home/local_key.pub"
}

commit_in_scratch_repo() {
  local home="$1" auth_sock="$2"
  shift 2
  local repo="$home/scratch-repo"
  mkdir -p "$repo"
  (
    cd "$repo" || exit 1
    "$@" HOME="$home" SSH_AUTH_SOCK="$auth_sock" git init -q &&
      echo hello > file.txt &&
      "$@" HOME="$home" SSH_AUTH_SOCK="$auth_sock" git add file.txt &&
      "$@" HOME="$home" SSH_AUTH_SOCK="$auth_sock" git commit -q -S -m "test commit"
  )
}

signed_with_key() {
  local home="$1" expected_pub="$2"
  local repo="$home/scratch-repo"
  local allowed="$home/allowed_signers"
  printf 'test@example.com %s\n' "$(cat "$expected_pub")" > "$allowed"
  HOME="$home" git -C "$repo" -c gpg.ssh.allowedSignersFile="$allowed" log --show-signature -1 2>&1 |
    grep -q 'Good "git" signature'
}

# ── Test: local-only, no forwarded agent, only the local (Secretive) one ───

HOME1=$(new_home)
write_gitconfig "$HOME1"
setup_local_agent "$HOME1"

commit_in_scratch_repo "$HOME1" "$HOME1/.ssh/agent.sock" env
assert "local-only: signs with the local key" signed_with_key "$HOME1" "$HOME1/local_key.pub"

# ── Test: forwarded agent already linked at agent.sock ──────────────────────

HOME2=$(new_home)
write_gitconfig "$HOME2"
mkdir -p -m 700 "$HOME2/.ssh"
FORWARDED2="$HOME2/forwarded-agent.sock"
agent_pids+=("$(start_agent "$FORWARDED2")")
ssh-keygen -q -t ed25519 -N '' -f "$HOME2/forwarded_key" -C forwarded
SSH_AUTH_SOCK="$FORWARDED2" ssh-add "$HOME2/forwarded_key" >/dev/null 2>&1
ln -sf "$FORWARDED2" "$HOME2/.ssh/agent.sock"

commit_in_scratch_repo "$HOME2" "$HOME2/.ssh/agent.sock" env
assert "forwarded: signs with the forwarded key" signed_with_key "$HOME2" "$HOME2/forwarded_key.pub"

# ── Test: torn-down forwarded agent, no shell prompt in between ────────────
# The scenario the whole plan exists for: agent.sock is a dangling symlink
# left by a forwarded session that already ended. SSH_AUTH_SOCK is exported
# (as it would be by a shell or launchd long ago) but nothing has refreshed
# the symlink's target since. Signed from a bare `env -i` process (no
# shell init, no PATH beyond the OS defaults) to prove the healing doesn't
# depend on a shell prompt having drawn.

HOME3=$(new_home)
write_gitconfig "$HOME3"
setup_local_agent "$HOME3"
SECRETIVE3="$HOME3/Library/Containers/com.maxgoedjen.Secretive.SecretAgent/Data/socket.ssh"
mkdir -p -m 700 "$HOME3/.ssh"
ln -sf "$HOME3/torn-down.sock" "$HOME3/.ssh/agent.sock"

commit_in_scratch_repo "$HOME3" "$HOME3/.ssh/agent.sock" env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin
assert "torn-down gap: self-heals and signs with the local key" \
  signed_with_key "$HOME3" "$HOME3/local_key.pub"
assert "torn-down gap: agent.sock healed to the local (Secretive) socket" \
  test "$HOME3/.ssh/agent.sock" -ef "$SECRETIVE3"

# ── Results ──────────────────────────────────────────────────────────────────

print_results
