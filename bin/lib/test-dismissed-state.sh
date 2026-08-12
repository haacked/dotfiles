#!/bin/bash
# Tests for the dismissed_comments state plumbing shared by copilot-review-loop.sh
# and the address-pr-reviews skill: the normalizing jq constants in copilot.sh,
# the record-dismissed-comment.sh writer, and fetch-unaddressed-comments.sh's
# filtering against state files in either entry shape (objects from the loop,
# legacy bare hash strings from older skill runs).
#
# Usage: test-dismissed-state.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/lib/copilot.sh
source "$SCRIPT_DIR/copilot.sh"

RECORD="$REPO_ROOT/ai/skills/address-pr-reviews/scripts/record-dismissed-comment.sh"
FETCH="$REPO_ROOT/ai/skills/address-pr-reviews/scripts/fetch-unaddressed-comments.sh"

# All temp artifacts live under one dir so a single trap cleans them up.
TESTTMP="$(mktemp -d)"
trap 'rm -rf "$TESTTMP"' EXIT

# ── The normalizing constants ────────────────────────────────────────────────

# Apply the production programs to a JSON document on stdin.
hashes() { jq -r "$DISMISSED_OBJECTS_JQ"' | .body_hash'; }
hash_rounds() { jq -r "$DISMISSED_HASH_ROUNDS_JQ"; }

out=$(printf '%s' '{"dismissed_comments":[{"body_hash":"h1","round":1},{"body_hash":"h2","body_preview":"p","round":2}]}' | hashes)
assert "object entries yield their hashes" test "$out" = "$(printf 'h1\nh2')"

out=$(printf '%s' '{"dismissed_comments":["h1","h2"]}' | hashes)
assert "bare-string entries normalize to hashes" test "$out" = "$(printf 'h1\nh2')"

out=$(printf '%s' '{"dismissed_comments":["h1",{"body_hash":"h2","round":3}]}' | hashes)
assert "mixed entries all normalize" test "$out" = "$(printf 'h1\nh2')"

rc=0; out=$(printf '%s' '{"dismissed_comments":[]}' | hashes) || rc=$?
assert "empty array exits 0" test "$rc" -eq 0
assert "empty array emits nothing" test -z "$out"

rc=0; out=$(printf '%s' '{"rounds":[]}' | hashes) || rc=$?
assert "missing key exits 0" test "$rc" -eq 0
assert "missing key emits nothing" test -z "$out"

rc=0; out=$(printf '%s' '{"dismissed_comments":null}' | hashes) || rc=$?
assert "null value exits 0" test "$rc" -eq 0
assert "null value emits nothing" test -z "$out"

out=$(printf '%s' '{"dismissed_comments":["bare1",{"body_hash":"h2","round":2},{"body_hash":"h3","round":0},{"round":9}]}' | hash_rounds)
expected=$(printf 'bare1\t?\nh2\t2\nh3\t0')
assert "TSV: bare entry gets round ?, round 0 stays 0, hashless entry dropped" \
  test "$out" = "$expected"

# ── dismissed_state_file / read_state_file ───────────────────────────────────

assert "state path derives owner-repo-pr under HOME" \
  test "$(HOME="$TESTTMP" dismissed_state_file acme/widgets 123)" = "$TESTTMP/.local/state/copilot-review-loop/acme-widgets-123.json"

out=$(read_state_file "$TESTTMP/does-not-exist.json")
assert "read_state_file defaults when the file is missing" \
  test "$out" = '{"dismissed_comments":[],"rounds":[]}'

printf '{bad' > "$TESTTMP/corrupt.json"
rc=0; read_state_file "$TESTTMP/corrupt.json" >/dev/null 2>&1 || rc=$?
assert "read_state_file fails on unparseable input" test "$rc" -ne 0

printf '[]' > "$TESTTMP/array.json"
rc=0; read_state_file "$TESTTMP/array.json" >/dev/null 2>&1 || rc=$?
assert "read_state_file rejects non-object documents" test "$rc" -ne 0

# ── record-dismissed-comment.sh ──────────────────────────────────────────────

RECORD_HOME="$TESTTMP/record-home"
mkdir -p "$RECORD_HOME"
record_state_dir="$RECORD_HOME/.local/state/copilot-review-loop"

record() {  # $1 = pr number; body on stdin
  env HOME="$RECORD_HOME" DOTFILES_DIR="$REPO_ROOT" "$RECORD" acme/widgets "$1" >/dev/null 2>&1
}

long_body='This body has "quotes" and embedded detail long enough to exceed the eighty byte preview boundary for sure.'
state_file="$record_state_dir/acme-widgets-123.json"

rc=0; printf '%s' "$long_body" | record 123 || rc=$?
assert "record: first run exits 0" test "$rc" -eq 0
assert "record: creates the state file" test -f "$state_file"
assert "record: one entry recorded" test "$(jq '.dismissed_comments | length' "$state_file")" -eq 1
assert "record: body_hash matches hash_comment" \
  test "$(jq -r '.dismissed_comments[0].body_hash' "$state_file")" = "$(hash_comment "$long_body")"
assert "record: body_preview is the first 80 bytes" \
  test "$(jq -r '.dismissed_comments[0].body_preview' "$state_file")" = "$(printf '%s' "$long_body" | head -c 80)"
assert "record: entry has no round key" \
  test "$(jq '.dismissed_comments[0] | has("round")' "$state_file")" = "false"

rc=0; printf '%s' "$long_body" | record 123 || rc=$?
assert "record: re-run exits 0" test "$rc" -eq 0
assert "record: re-run appends nothing" test "$(jq '.dismissed_comments | length' "$state_file")" -eq 1

# A hash already present as a legacy bare string is recognized: no duplicate,
# and the legacy entry survives as a bare string (value-level; jq re-serializes).
legacy_file="$record_state_dir/acme-widgets-124.json"
legacy_body="a legacy comment"
printf '%s' "{\"dismissed_comments\":[\"$(hash_comment "$legacy_body")\"],\"rounds\":[{\"round\":1}]}" > "$legacy_file"

rc=0; printf '%s' "$legacy_body" | record 124 || rc=$?
assert "record: legacy bare-string hash is a no-op" test "$rc" -eq 0
assert "record: no duplicate next to the legacy entry" test "$(jq '.dismissed_comments | length' "$legacy_file")" -eq 1
assert "record: legacy entry survives as a bare string" \
  test "$(jq -r '.dismissed_comments[0] | type' "$legacy_file")" = "string"

rc=0; printf '%s' "a brand new comment" | record 124 || rc=$?
assert "record: append alongside legacy exits 0" test "$rc" -eq 0
assert "record: new object appended after legacy entry" test "$(jq '.dismissed_comments | length' "$legacy_file")" -eq 2
assert "record: legacy entry still a bare string after append" \
  test "$(jq -r '.dismissed_comments[0] | type' "$legacy_file")" = "string"
assert "record: appended entry carries the new hash" \
  test "$(jq -r '.dismissed_comments[1].body_hash' "$legacy_file")" = "$(hash_comment "a brand new comment")"
assert "record: rounds key preserved" test "$(jq '.rounds | length' "$legacy_file")" -eq 1

missing_file="$record_state_dir/acme-widgets-125.json"
rc=0; printf '' | record 125 || rc=$?
assert "record: empty stdin rejected" test "$rc" -ne 0
assert_not "record: empty stdin creates no file" test -f "$missing_file"

rc=0; printf '  \n\t ' | record 125 || rc=$?
assert "record: whitespace-only stdin rejected" test "$rc" -ne 0
assert_not "record: whitespace stdin creates no file" test -f "$missing_file"

corrupt_file="$record_state_dir/acme-widgets-126.json"
printf '{bad' > "$corrupt_file"
rc=0; printf '%s' "some body" | record 126 || rc=$?
assert "record: corrupt state file rejected" test "$rc" -ne 0
assert "record: corrupt file left unchanged" test "$(cat "$corrupt_file")" = "{bad"

# ── fetch-unaddressed-comments.sh end-to-end ─────────────────────────────────

# gh shim: ignores its arguments and prints the canned GraphQL response, so the
# fetch script (executed, not sourced) resolves it via PATH with no network.
mkdir -p "$TESTTMP/bin"
cat > "$TESTTMP/bin/gh" <<'SHIM'
#!/bin/bash
cat "$GH_FIXTURE"
SHIM
chmod +x "$TESTTMP/bin/gh"

body_dismissed="dismissed one"
body_fresh="fresh one"
dismissed_hash=$(hash_comment "$body_dismissed")
fresh_hash=$(hash_comment "$body_fresh")

fixture="$TESTTMP/gh-fixture.json"
cat > "$fixture" <<JSON
{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 101, "path": "src/a.py", "line": 10, "body": "$body_dismissed", "diffHunk": "@@", "author": {"login": "Copilot", "__typename": "Bot"}}
  ]}},
  {"isResolved": false, "comments": {"nodes": [
    {"databaseId": 102, "path": "src/b.py", "line": 20, "body": "$body_fresh", "diffHunk": "@@", "author": {"login": "octocat", "__typename": "User"}}
  ]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}
JSON

run_fetch() {  # $1 = fake home dir
  run_bounded 10 env HOME="$1" DOTFILES_DIR="$REPO_ROOT" \
    PATH="$TESTTMP/bin:$PATH" GH_FIXTURE="$fixture" "$FETCH" acme/widgets 123
}

seed_state() {  # $1 = fake home dir, $2 = state file JSON
  mkdir -p "$1/.local/state/copilot-review-loop"
  printf '%s' "$2" > "$1/.local/state/copilot-review-loop/acme-widgets-123.json"
}

# The reported regression: a hash recorded as a bare string must still filter
# out its comment.
home_bare="$TESTTMP/fetch-bare"
seed_state "$home_bare" "{\"dismissed_comments\":[\"$dismissed_hash\"],\"rounds\":[]}"
rc=0; out=$(run_fetch "$home_bare") || rc=$?
assert "fetch: bare-string state exits 0" test "$rc" -eq 0
assert "fetch: bare-string hash filters its comment" test "$(echo "$out" | jq 'length')" -eq 1
assert "fetch: survivor is the fresh comment" test "$(echo "$out" | jq -r '.[0].body')" = "$body_fresh"

home_obj="$TESTTMP/fetch-obj"
seed_state "$home_obj" "{\"dismissed_comments\":[{\"body_hash\":\"$dismissed_hash\",\"round\":1}],\"rounds\":[]}"
rc=0; out=$(run_fetch "$home_obj") || rc=$?
assert "fetch: object state exits 0" test "$rc" -eq 0
assert "fetch: object hash filters its comment" test "$(echo "$out" | jq 'length')" -eq 1
assert "fetch: object-state survivor is the fresh comment" test "$(echo "$out" | jq -r '.[0].body')" = "$body_fresh"

home_mixed="$TESTTMP/fetch-mixed"
seed_state "$home_mixed" "{\"dismissed_comments\":[\"$dismissed_hash\",{\"body_hash\":\"$fresh_hash\",\"round\":2}],\"rounds\":[]}"
rc=0; out=$(run_fetch "$home_mixed") || rc=$?
assert "fetch: mixed state exits 0" test "$rc" -eq 0
assert "fetch: mixed state filters both comments" test "$(echo "$out" | jq 'length')" -eq 0

home_none="$TESTTMP/fetch-none"
mkdir -p "$home_none"
rc=0; out=$(run_fetch "$home_none") || rc=$?
assert "fetch: missing state file exits 0" test "$rc" -eq 0
assert "fetch: missing state file passes everything through" test "$(echo "$out" | jq 'length')" -eq 2

# A state file that exists but cannot be parsed must fail the run rather than
# silently resurfacing every previously-dismissed comment.
home_corrupt="$TESTTMP/fetch-corrupt"
seed_state "$home_corrupt" '{bad'
rc=0; out=$(run_fetch "$home_corrupt") || rc=$?
assert "fetch: corrupt state file fails" test "$rc" -ne 0
assert "fetch: corrupt state is a failure, not a hang" test "$rc" -ne 124

# ── Results ─────────────────────────────────────────────────────────────────

print_results
