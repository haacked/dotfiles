#!/bin/bash
# Tests for the session record that bin/vault-ingest-run leaves for
# `vault-ingest-service.sh resume`.
#
# Usage: test-vault-ingest-run.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RUNNER="$SCRIPT_DIR/../vault-ingest-run"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

TESTTMP=$(mktemp -d)
trap 'rm -rf "$TESTTMP"' EXIT

STUB_BIN="$TESTTMP/stubs"
RUN_LOG="$TESTTMP/run.log"
SESSION="00000000-0000-4000-8000-000000000000"
mkdir -p "$STUB_BIN"

write_passthrough_shims "$STUB_BIN"
printf '#!/bin/sh\n' >"$STUB_BIN/claude"
cat >"$STUB_BIN/uuidgen" <<STUB
#!/bin/bash
echo $SESSION
STUB
chmod +x "$STUB_BIN/claude" "$STUB_BIN/uuidgen"

# Builds a fake HOME with the notes vault and the vault skill's scripts. The
# backlog script prints one source per argument.
fake_home() { # name backlog-source...
    local home="$TESTTMP/$1" scripts
    shift
    scripts="$home/.claude/skills/vault/scripts"
    mkdir -p "$home/dev/haacked/notes/PostHog" "$scripts"
    printf '#!/bin/sh\nprintf "== Dead wikilinks ==\\n(none)\\n"\n' >"$scripts/vault-lint-links.sh"
    {
        printf '#!/bin/sh\n'
        [[ $# -eq 0 ]] || printf 'printf "%%s\\n" %s\n' "$*"
    } >"$scripts/vault-next-source.sh"
    chmod +x "$scripts/vault-lint-links.sh" "$scripts/vault-next-source.sh"
    printf '%s\n' "$home"
}

# jq stays on PATH, because without it the automation directory reads as
# signed out.
run_ingest() { # home
    RUN_STATUS=0
    (
        unset CLAUDE_CONFIG_DIR
        HOME="$1" PATH="$STUB_BIN:$PATH" "$RUNNER"
    ) >"$RUN_LOG" 2>&1 || RUN_STATUS=$?
}

state_file() { # home name
    cat "$1/.local/state/vault-ingest/$2" 2>/dev/null || echo missing
}

# ── Test: a run under the automation account records it ───────────────────

home=$(fake_home automation raw/a.md)
mkdir -p "$home/.claude-automation"
printf '%s\n' '{"oauthAccount": {"emailAddress": "bot@example.com", "organizationName": "Example Org"}}' \
    >"$home/.claude-automation/.claude.json"

run_ingest "$home"

assert "An automation run exits 0" test "$RUN_STATUS" -eq 0
assert "An automation run records the session ID" test "$(state_file "$home" last-session-id)" = "$SESSION"
assert "An automation run records the automation account's config directory" \
    test "$(state_file "$home" last-session-config-dir)" = "$home/.claude-automation"

# ── Test: a run on the default login records an empty config directory ────

home=$(fake_home default raw/a.md)

run_ingest "$home"

assert "A default-login run exits 0" test "$RUN_STATUS" -eq 0
assert "A default-login run records the session ID" test "$(state_file "$home" last-session-id)" = "$SESSION"
assert "A default-login run records an empty config directory" \
    test "$(state_file "$home" last-session-config-dir)" = ""

# ── Test: a run with an empty backlog records no session ──────────────────

home=$(fake_home empty)

run_ingest "$home"

assert "An empty-backlog run exits 0" test "$RUN_STATUS" -eq 0
assert "An empty-backlog run records no session, because claude never ran" \
    test "$(state_file "$home" last-session-id)" = missing

print_results
