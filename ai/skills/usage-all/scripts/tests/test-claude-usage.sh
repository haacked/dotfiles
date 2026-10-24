#!/usr/bin/env bash
# Tests for claude-usage, the plan usage report for every signed-in Claude
# account.
#
# Every account comes from a fixture, so every case is offline:
# - A `security` shim answers keychain lookups from $KEYCHAIN/<service>.
# - A `curl` shim answers from $RESPONSES/<token>.json and <token>.status, and
#   fails like a timeout when <token>.fail exists.
# - A `claude` shim stands in for the token refresh: it copies
#   $REFRESHED/<service> over the keychain entry when that file exists.
# - A `python3` shim prints $PYTHON_WARNING to stderr and runs the real
#   interpreter.
# The shims append one line per call to $CALLS. PATH holds the shims and links
# to the few system tools the script needs, so the real claude, curl, and
# security stay invisible.
# Each case writes docket's config.toml and limits.jsonl under $DOCKET_HOME,
# and the real run-review.py from the go skill reads them.
#
# Usage: test-claude-usage.sh

# The expected output holds literal backticks and tildes.
# shellcheck disable=SC2016,SC2088

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN="$SCRIPT_DIR/../claude-usage"

passes=0
failures=0
TEST_ROOT="$(mktemp -d)" || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

check() {
  if [ "$2" = "$3" ]; then
    passes=$((passes + 1))
  else
    echo "FAIL: $1"
    diff <(printf '%s\n' "$2") <(printf '%s\n' "$3") | sed 's/^/  /'
    failures=$((failures + 1))
  fi
}

TOOLS="$TEST_ROOT/tools"
SHIMS="$TEST_ROOT/shims"
mkdir -p "$TOOLS" "$SHIMS"
for tool in bash jq shasum perl cut dirname grep head cat cp date env mktemp rm sed; do
  ln -s "$(command -v "$tool")" "$TOOLS/$tool"
done
# A version manager's python3 shim cannot run from another PATH, so the shim
# runs the interpreter itself.
REAL_PYTHON="$(python3 -c 'import sys; print(sys.executable)')"
export REAL_PYTHON

cat >"$SHIMS/security" <<'SHIM'
#!/usr/bin/env bash
echo "security $*" >>"$CALLS"
[ "$1" = find-generic-password ] && [ "$2" = -s ] && [ "$4" = -w ] || exit 2
cat "$KEYCHAIN/$3" 2>/dev/null || exit 44
SHIM

cat >"$SHIMS/curl" <<'SHIM'
#!/usr/bin/env bash
echo "curl $*" >>"$CALLS"
token="$(sed -n 's/^Authorization: Bearer //p')"
echo "auth $token" >>"$CALLS"
if [ -e "$RESPONSES/$token.fail" ]; then
  echo "curl: (28) Operation timed out after 15001 milliseconds" >&2
  printf '\n000'
  exit 28
fi
cat "$RESPONSES/$token.json" 2>/dev/null
printf '\n%s' "$(cat "$RESPONSES/$token.status" 2>/dev/null || echo 401)"
SHIM

cat >"$SHIMS/claude" <<'SHIM'
#!/usr/bin/env bash
echo "claude CLAUDE_CONFIG_DIR=${CLAUDE_CONFIG_DIR-<unset>} $*" >>"$CALLS"
service="Claude Code-credentials"
if [ -n "${CLAUDE_CONFIG_DIR-}" ]; then
  service+="-$(printf '%s' "$CLAUDE_CONFIG_DIR" | shasum -a 256 | cut -c1-8)"
fi
[ -e "$REFRESHED/$service" ] && cp "$REFRESHED/$service" "$KEYCHAIN/$service"
exit 1
SHIM
cat >"$SHIMS/python3" <<'SHIM'
#!/usr/bin/env bash
if [ -n "${PYTHON_WARNING-}" ]; then
  echo "$PYTHON_WARNING" >&2
fi
exec "$REAL_PYTHON" "$@"
SHIM
chmod +x "$SHIMS"/*

export TZ=UTC
# 2026-10-23T23:00:00Z
export CLAUDE_USAGE_NOW=1792796400
FUTURE_MS=$(((CLAUDE_USAGE_NOW + 3600) * 1000))
PAST_MS=$(((CLAUDE_USAGE_NOW - 3600) * 1000))

# The keychain service name, computed apart from the script under test.
service() {
  if [ -z "$1" ]; then
    echo "Claude Code-credentials"
  else
    echo "Claude Code-credentials-$(python3 -I -c 'import hashlib, sys; print(hashlib.sha256(sys.argv[1].encode()).hexdigest()[:8])' "$1")"
  fi
}

creds() {
  jq -cn --arg token "$1" --argjson expires "$2" --arg plan "$3" --arg tier "$4" \
    '{claudeAiOauth: {accessToken: $token, refreshToken: "refresh-\($token)", expiresAt: $expires,
                      subscriptionType: $plan, rateLimitTier: $tier}}'
}

signed_in() {
  local file="$1" email="$2" org="$3"
  mkdir -p "$(dirname "$file")"
  jq -n --arg email "$email" --arg org "$org" \
    '{oauthAccount: {emailAddress: $email, organizationName: $org}}' >"$file"
}

respond() {
  printf '%s' "$2" >"$RESPONSES/$1.json"
  printf '%s' "${3:-200}" >"$RESPONSES/$1.status"
}

USAGE_DEFAULT='{
  "limits": [
    {"kind": "session", "percent": 31, "severity": "normal", "resets_at": "2026-10-24T02:19:59.852356+00:00"},
    {"kind": "weekly_all", "percent": 78, "severity": "warning", "resets_at": "2026-10-28T19:59:59.852371+00:00"},
    {"kind": "weekly_scoped", "percent": 0, "severity": "normal", "resets_at": "2026-10-28T20:00:00+00:00",
     "scope": {"model": {"display_name": "Fable"}}}
  ],
  "spend": {"used": {"amount_minor": 26057, "currency": "USD", "exponent": 2},
            "limit": {"amount_minor": 50000, "currency": "USD", "exponent": 2},
            "percent": 52, "enabled": false, "disabled_reason": "out_of_credits"}
}'
USAGE_TEAM='{
  "limits": [
    {"kind": "session", "percent": 0, "severity": "normal", "resets_at": null},
    {"kind": "weekly_all", "percent": 100, "severity": "critical", "resets_at": "2026-10-24T04:00:00-07:00"}
  ],
  "spend": {"used": {"amount_minor": 100005, "currency": "USD", "exponent": 2},
            "limit": {"amount_minor": 100000, "currency": "USD", "exponent": 2},
            "percent": 100, "enabled": true, "disabled_reason": null}
}'
USAGE_PERSONAL='{
  "limits": [
    {"kind": "session", "percent": 5, "severity": "normal", "resets_at": "2026-10-23T23:45:00Z"}
  ],
  "spend": {"used": {"amount_minor": 0, "currency": "USD", "exponent": 2}, "limit": null,
            "percent": 0, "enabled": false, "disabled_reason": null}
}'

# Builds a fresh fixture home: the default login, a team login whose token has
# expired, a personal login, a directory that never signed in, and a docket
# config that rotates through the team login and then the default login.
setup() {
  local case_root="$TEST_ROOT/$1"
  export HOME="$case_root/home" KEYCHAIN="$case_root/keychain" RESPONSES="$case_root/responses"
  export REFRESHED="$case_root/refreshed" CALLS="$case_root/calls" DOCKET_HOME="$case_root/docket"
  unset CLAUDE_CONFIG_DIR
  mkdir -p "$HOME/.claude-prompts" "$KEYCHAIN" "$RESPONSES" "$REFRESHED" "$DOCKET_HOME"
  : >"$CALLS"
  printf '%s\n' 'claude_config_dir = "~/.claude-team"' 'claude_fallback_config_dirs = ["~/.claude"]' \
    >"$DOCKET_HOME/config.toml"

  signed_in "$HOME/.claude.json" d@example.com "d@example.com's Organization"
  creds tok-default "$FUTURE_MS" max default_claude_max_20x >"$KEYCHAIN/$(service "")"
  respond tok-default "$USAGE_DEFAULT"

  signed_in "$HOME/.claude-team/.claude.json" t@example.com Acme
  creds tok-team-old "$PAST_MS" team default_claude_max_5x >"$KEYCHAIN/$(service "$HOME/.claude-team")"
  creds tok-team "$FUTURE_MS" team default_claude_max_5x >"$REFRESHED/$(service "$HOME/.claude-team")"
  respond tok-team "$USAGE_TEAM"

  signed_in "$HOME/.claude-personal/.claude.json" p@example.com "p@example.com's Organization"
  creds tok-personal "$FUTURE_MS" pro "" >"$KEYCHAIN/$(service "$HOME/.claude-personal")"
  respond tok-personal "$USAGE_PERSONAL"
}

run() {
  env PATH="$SHIMS:$TOOLS" "$BIN" "$@"
}

# Records a docket limit on an account that lasts past any real clock this
# suite runs under. An empty account is the default login.
limit() {
  jq -cn --arg account "$1" '{account: $account, at: "2026-10-23T22:00:00Z", until: "2099-01-01T00:00:00Z"}' \
    >>"$DOCKET_HOME/limits.jsonl"
}

PERSONAL_BLOCK='p@example.com · Pro · ~/.claude-personal
  Session (5h)          5%  █░░░░░░░░░░░░░░░░░░░  resets today 11:45 PM (in 45m)
'

# --- The report covers each signed-in directory and refreshes expired tokens.
setup report
out="$(run 2>&1)"
expected='d@example.com · Max 20x · default login
  Session (5h)         31%  ██████░░░░░░░░░░░░░░  resets tomorrow 2:20 AM (in 3h 20m)
  Week (all models)    78%  ████████████████░░░░  resets Wed Oct 28 8:00 PM (in 4d 21h)  ⚠ warning
  Week (Fable)          0%  ░░░░░░░░░░░░░░░░░░░░  resets Wed Oct 28 8:00 PM (in 4d 21h)
  Extra usage          52%  $260.57 of $500.00 · off (out of credits)

p@example.com · Pro · ~/.claude-personal
  Session (5h)          5%  █░░░░░░░░░░░░░░░░░░░  resets today 11:45 PM (in 45m)

t@example.com · Team 5x · Acme · ~/.claude-team
  Session (5h)          0%  ░░░░░░░░░░░░░░░░░░░░
  Week (all models)   100%  ████████████████████  resets tomorrow 11:00 AM (in 12h 0m)  ⚠ critical
  Extra usage         100%  $1000.05 of $1000.00

docket and /go run Claude reviews on ~/.claude-team, then the default login.
The next review runs on ~/.claude-team.'
check "the report renders each account's limits, extra usage, and review accounts" "$expected" "$out"
check "claude refreshes only the expired token, under its own config dir" \
  "claude CLAUDE_CONFIG_DIR=$HOME/.claude-team mcp get claude-usage-refresh" \
  "$(grep '^claude ' "$CALLS")"
check "no access token reaches curl's arguments" "" "$(grep '^curl ' "$CALLS" | grep -o 'tok-[a-z-]*')"
check "curl reads each token from stdin" "auth tok-default
auth tok-personal
auth tok-team" "$(grep '^auth ' "$CALLS" | sort)"

# --- --json prints the response and the plan, and none of the credentials.
setup json
out="$(run --json)"
check "--json gives each account's dir, plan, and tier" \
  '[null,"max","default_claude_max_20x",null]
["'"$HOME"'/.claude-personal","pro","",null]
["'"$HOME"'/.claude-team","team","default_claude_max_5x",null]' \
  "$(jq -c '.accounts[] | [.dir, .plan, .tier, .error]' <<<"$out")"
check "--json passes the usage response through" "$(jq -c . <<<"$USAGE_DEFAULT")" "$(jq -c '.accounts[0].usage' <<<"$out")"
check "--json passes the review accounts through" \
  '{"rotation":["'"$HOME"'/.claude-team",""],"order":["'"$HOME"'/.claude-team",""],"limits":{}}' \
  "$(jq -c '.reviews' <<<"$out")"
check "--json leaves out the tokens" "" "$(grep -o 'tok-[a-z-]*\|refresh-' <<<"$out")"

# --- A token that claude cannot refresh names the login to run.
setup no-refresh
rm "$REFRESHED"/*
out="$(run --json "$HOME/.claude-team")"
check "an unrefreshable token reports the fix" \
  'the access token expired and claude could not refresh it; run `CLAUDE_CONFIG_DIR=~/.claude-team claude` and /login' \
  "$(jq -r '.accounts[0].error' <<<"$out")"
check "an unrefreshable token makes no usage request" "" "$(grep '^curl ' "$CALLS")"

# --- The default login refreshes with CLAUDE_CONFIG_DIR unset.
setup default-refresh
creds tok-default "$PAST_MS" max default_claude_max_20x >"$KEYCHAIN/$(service "")"
creds tok-default "$FUTURE_MS" max default_claude_max_20x >"$REFRESHED/$(service "")"
out="$(CLAUDE_CONFIG_DIR="$HOME/.claude-team" run --json "")"
check "the default login refreshes without the inherited CLAUDE_CONFIG_DIR" \
  "claude CLAUDE_CONFIG_DIR=<unset> mcp get claude-usage-refresh" "$(grep '^claude ' "$CALLS")"
check "the default login reports usage after the refresh" "null" "$(jq -r '.accounts[0].error' <<<"$out")"

# --- ~/.claude names the default login, and a trailing slash names the same dir.
setup arguments
out="$(run --json "$HOME/.claude" "$HOME/.claude-personal/")"
check "~/.claude and a trailing slash resolve to the logins claude uses" \
  "[null,null]
[\"$HOME/.claude-personal\",null]" "$(jq -c '.accounts[] | [.dir, .error]' <<<"$out")"

# --- Two spellings of one directory fetch once, so only one refresh runs.
setup duplicates
out="$(run --json "$HOME/.claude-team" "$HOME/.claude-team/")"
check "a directory named twice is one account" \
  "[\"$HOME/.claude-team\",null]" "$(jq -c '.accounts[] | [.dir, .error]' <<<"$out")"
check "a directory named twice refreshes once" 1 "$(grep -c '^claude ' "$CALLS")"

# --- Each failure names its cause.
setup failures
signed_in "$HOME/.claude-gone/.claude.json" g@example.com Gone
respond tok-personal '{"error": "unauthorized"}' 401
touch "$RESPONSES/tok-default.fail"
out="$(run --json "" "$HOME/.claude-personal" "$HOME/.claude-gone")"
check "each failure names its cause" \
  'the usage request failed: curl: (28) Operation timed out after 15001 milliseconds
the usage endpoint answered HTTP 401
not signed in; run `CLAUDE_CONFIG_DIR=~/.claude-gone claude` and /login' \
  "$(jq -r '.accounts[].error' <<<"$out")"
out="$(run "$HOME/.claude-gone")"
check "the report shows a failure under its account" \
  'g@example.com · unknown plan · Gone · ~/.claude-gone
  ✗ not signed in; run `CLAUDE_CONFIG_DIR=~/.claude-gone claude` and /login

docket and /go run Claude reviews on ~/.claude-team, then the default login.
The next review runs on ~/.claude-team.' "$out"

# --- Without a keychain, the credentials come from .credentials.json.
setup files
mv "$SHIMS/security" "$SHIMS/security.off"
mkdir -p "$HOME/.claude"
creds tok-default "$FUTURE_MS" max default_claude_max_20x >"$HOME/.claude/.credentials.json"
creds tok-personal "$FUTURE_MS" pro "" >"$HOME/.claude-personal/.credentials.json"
out="$(run --json "" "$HOME/.claude-personal")"
mv "$SHIMS/security.off" "$SHIMS/security"
check "without a keychain each login reads its .credentials.json" "null
null" "$(jq -r '.accounts[].error' <<<"$out")"

# --- An account that only docket names joins the report once.
setup docket-only
printf '%s\n' 'claude_config_dir = "~/work claude"' 'claude_fallback_config_dirs = ["~/.claude", "~/.claude-team"]' \
  >"$DOCKET_HOME/config.toml"
signed_in "$HOME/work claude/.claude.json" w@example.com Work
creds tok-work "$FUTURE_MS" team "" >"$KEYCHAIN/$(service "$HOME/work claude")"
respond tok-work "$USAGE_PERSONAL"
out="$(run --json)"
check "docket's accounts join the discovered ones once" \
  "[null,null]
[\"$HOME/.claude-personal\",null]
[\"$HOME/.claude-team\",null]
[\"$HOME/work claude\",null]" "$(jq -c '.accounts[] | [.dir, .error]' <<<"$out")"

# --- A recorded limit moves the next review to the next account.
setup limited
limit "$HOME/.claude-team"
check "the report names the next account and the recorded limit" \
  "${PERSONAL_BLOCK}
docket and /go run Claude reviews on ~/.claude-team, then the default login.
The next review runs on the default login.
docket recorded a usage limit on ~/.claude-team that resets Thu Jan 1 12:00 AM (in 26367d 1h)." \
  "$(run "$HOME/.claude-personal")"

# --- With every docket account limited, /go falls back to the session's account.
setup all-limited
limit "$HOME/.claude-team"
limit ""
check "every limited account sends the next review to the session's account" \
  "Every account in docket's rotation is over a recorded limit, so /go runs the next review on this session's account, ~/.claude-personal." \
  "$(CLAUDE_CONFIG_DIR="$HOME/.claude-personal" run "$HOME/.claude-personal" | sed -n '5p')"
check "every limited account in a rotation that holds the session's account stops /go" \
  "Every account in docket's rotation is over a recorded limit, so /go refuses to start a review." \
  "$(run "$HOME/.claude-personal" | sed -n '5p')"

# --- Without a docket config, /go reviews on the session's account.
setup no-docket
rm "$DOCKET_HOME/config.toml"
check "no docket config names the session's account" \
  "${PERSONAL_BLOCK}
docket's config.toml names no accounts, so /go runs Claude reviews on this session's account, the default login." \
  "$(run "$HOME/.claude-personal")"

# --- A docket config that run-review.py refuses shows its error.
setup bad-docket
printf '%s\n' 'claude_config_dir = "relative/dir"' >"$DOCKET_HOME/config.toml"
check "a docket config error shows under the accounts" \
  "${PERSONAL_BLOCK}
Cannot read the accounts that docket and /go review on: $DOCKET_HOME/config.toml names 'relative/dir', which is relative; give an absolute path or one that starts with ~" \
  "$(run "$HOME/.claude-personal")"

# --- A warning from run-review.py leaves the report intact.
setup runner-warning
out="$(PYTHON_WARNING="DeprecationWarning: fixture" run --json "$HOME/.claude-personal")"
check "stderr from run-review.py does not replace its accounts" \
  '["'"$HOME"'/.claude-team",""]' "$(jq -c '.reviews.rotation' <<<"$out")"

# --- A docket entry runs under the exact string that docket gives claude.
setup docket-spelling
printf '%s\n' "claude_config_dir = \"$HOME/.claude-team/\"" >"$DOCKET_HOME/config.toml"
creds tok-team-slash "$FUTURE_MS" team "" >"$KEYCHAIN/$(service "$HOME/.claude-team/")"
respond tok-team-slash "$USAGE_PERSONAL"
out="$(run --json)"
check "a docket entry with a trailing slash is its own account" \
  "[null,null]
[\"$HOME/.claude-personal\",null]
[\"$HOME/.claude-team\",null]
[\"$HOME/.claude-team/\",null]" "$(jq -c '.accounts[] | [.dir, .error]' <<<"$out")"
check "the docket entry reads the keychain entry for its exact string" \
  "auth tok-team-slash" "$(grep '^auth tok-team-slash' "$CALLS")"

# --- Null fields and an empty limit list still render the account.
setup sparse
respond tok-personal '{"limits": [{"kind": "session", "percent": null, "resets_at": null}],
  "spend": {"used": null, "limit": null, "percent": null, "enabled": true}}'
respond tok-team '{"limits": [], "spend": {"used": {"amount_minor": 500, "currency": "EUR", "exponent": 2},
  "limit": null, "percent": null, "enabled": true}}'
check "null fields render as zero or not at all" \
  'p@example.com · Pro · ~/.claude-personal
  Session (5h)          0%  ░░░░░░░░░░░░░░░░░░░░

t@example.com · Team 5x · Acme · ~/.claude-team
  no limits reported
  Extra usage           0%  EUR 5.00' \
  "$(run "$HOME/.claude-personal" "$HOME/.claude-team" | sed -n '1,6p')"

# --- "today" and "tomorrow" follow the calendar across a daylight saving change.
setup dst
respond tok-personal '{"limits": [
  {"kind": "session", "percent": 1, "resets_at": "2027-03-14T17:00:00Z"},
  {"kind": "weekly_all", "percent": 1, "resets_at": "2027-03-15T07:10:00Z"}]}'
creds tok-personal 4102444800000 pro "" >"$KEYCHAIN/$(service "$HOME/.claude-personal")"
# 2027-03-13T23:30 PST, the night before clocks spring forward.
check "a reset the next calendar day reads tomorrow, and one two days out does not" \
  '  Session (5h)          1%  ░░░░░░░░░░░░░░░░░░░░  resets tomorrow 10:00 AM (in 9h 30m)
  Week (all models)     1%  ░░░░░░░░░░░░░░░░░░░░  resets Mon Mar 15 12:10 AM (in 23h 40m)' \
  "$(TZ=America/Los_Angeles CLAUDE_USAGE_NOW=1805009400 run "$HOME/.claude-personal" | sed -n '2,3p')"

# --- An unknown option prints the usage line.
setup option
run --bogus >/dev/null 2>&1
check "an unknown option exits 2" 2 "$?"

echo ""
echo "Results: $passes passed, $failures failed"
[ "$failures" -eq 0 ]
