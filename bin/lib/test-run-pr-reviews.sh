#!/bin/bash
# Offline tests for the engine boundary and overnight safety limits; shims prevent network requests.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

BIN="$(cd "$SCRIPT_DIR/.." && pwd)/run-pr-reviews.sh"
ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PLIST="$ROOT/macos/LaunchAgents/com.haacked.review-all-prs.plist"
SERVICE="$ROOT/bin/review-all-prs-service.sh"

TESTTMP="$(mktemp -d)"
TESTTMP="$(cd "$TESTTMP" && pwd -P)"
trap 'rm -rf "$TESTTMP"' EXIT

FAKE_HOME="$TESTTMP/home"
SHIM_BIN="$TESTTMP/bin"
CODEX_LOG="$TESTTMP/codex.log"
GH_LOG="$TESTTMP/gh.log"
mkdir -p "$FAKE_HOME" "$SHIM_BIN"

BASH4=""
for candidate in "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
  [[ -x "$candidate" ]] || continue
  # shellcheck disable=SC2016 # BASH_VERSINFO must expand in the candidate.
  if [[ "$("$candidate" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
    BASH4="$candidate"
    break
  fi
done
if [[ -z "$BASH4" ]]; then
  echo "No bash 4+ found; run-pr-reviews.sh cannot run. Install bash via Homebrew." >&2
  exit 1
fi
SHIM_PATH="$SHIM_BIN:$(dirname "$BASH4"):/usr/bin:/bin"

cat > "$SHIM_BIN/gh" <<'SHIM'
#!/bin/bash
printf '%s\n' "$*" >> "$GH_LOG"

if [[ "${1-}" == "auth" && "${2-}" == "status" ]]; then
  exit 0
fi
if [[ "${1-}" != "api" ]]; then
  echo '[]'
  exit 0
fi

case "${2-}" in
  user)
    echo 'me'
    ;;
  graphql)
    if [[ "${GH_AUTO_FIXTURE:-false}" == "true" ]]; then
      cat <<'JSON'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"edges":[{"node":{"number":99021,"title":"feat(flags): team fixture","url":"https://github.com/PostHog/posthog/pull/99021","repository":{"nameWithOwner":"PostHog/posthog"},"author":{"login":"team-dev"},"updatedAt":"2026-08-30T12:00:00Z","reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"committedDate":"2026-08-30T11:00:00Z"}}]}}},{"node":{"number":99022,"title":"feat(flags): outside fixture","url":"https://github.com/PostHog/posthog/pull/99022","repository":{"nameWithOwner":"PostHog/posthog"},"author":{"login":"outside-dev"},"updatedAt":"2026-08-30T12:00:00Z","reviews":{"nodes":[]},"commits":{"nodes":[{"commit":{"committedDate":"2026-08-30T11:00:00Z"}}]}}}]}}}
JSON
    else
      echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"edges":[]}}}'
    fi
    ;;
  orgs/*/teams/*/members*)
    if [[ "$*" == *"[.[].login]"* ]]; then
      echo '["team-dev"]'
    else
      echo 'team-dev'
    fi
    ;;
  orgs/*/members*)
    echo '[]'
    ;;
  repos/*/pulls/*/reviews)
    echo '[]'
    ;;
  repos/*/pulls/*/comments)
    echo '[{"user":{"login":"me"},"created_at":"2099-01-01T00:00:00Z"}]'
    ;;
  *)
    echo '[]'
    ;;
esac
SHIM

cat > "$SHIM_BIN/codex" <<'SHIM'
#!/bin/bash
if [[ "${1-}" == "login" && "${2-}" == "status" ]]; then
  exit 0
fi

printf '<%s>\n' "$@" >> "$CODEX_LOG"
call_number=$(grep -c '^<exec>$' "$CODEX_LOG")
if [[ "${CODEX_FAIL_FIRST:-false}" == "true" && "$call_number" -eq 1 ]]; then
  echo '{"type":"error","message":"fixture engine failure"}'
  exit 7
fi
if [[ "${CODEX_RATE_LIMIT:-false}" == "true" ]]; then
  cat <<'JSON'
{"type":"error","message":"You've hit your usage limit."}
JSON
  exit 1
fi
if [[ "${CODEX_AUTH_FAIL:-false}" == "true" ]]; then
  echo '{"type":"error","message":"status 401: unauthorized"}'
  exit 1
fi
echo '{"type":"item.completed","item":{"id":"item_0","type":"agent_message","text":"Codex fixture review result\n\nSecond fixture line"}}'
echo '{"type":"turn.completed","usage":{"input_tokens":101,"cached_input_tokens":17,"output_tokens":23}}'
SHIM

cat > "$SHIM_BIN/claude" <<'SHIM'
#!/bin/bash
if [[ "${CLAUDE_RATE_LIMIT:-false}" == "true" ]]; then
  echo '{"type":"error","error":{"type":"rate_limit_error"}}'
  exit 1
fi
if [[ "${CLAUDE_RATE_LIMIT_TEXT:-false}" == "true" ]]; then
  echo '{"type":"result","subtype":"success","result":"Claude fixture review covers rate limit handling"}'
else
  echo '{"type":"result","subtype":"success","result":"Claude fixture review result"}'
fi
SHIM

cat > "$SHIM_BIN/caffeinate" <<'SHIM'
#!/bin/bash
[[ "${1-}" == "-i" ]] && shift
exec "$@"
SHIM

cat > "$SHIM_BIN/timeout" <<'SHIM'
#!/bin/bash
while [[ "${1-}" == --* ]]; do shift; done
shift
exec "$@"
SHIM

chmod +x "$SHIM_BIN/gh" "$SHIM_BIN/codex" "$SHIM_BIN/claude" \
  "$SHIM_BIN/caffeinate" "$SHIM_BIN/timeout"

PR_ONE='[{"number":99011,"title":"feat(flags): first fixture","url":"https://github.com/PostHog/posthog/pull/99011","repo":"PostHog/posthog","author":"team-dev","user_review_state":null}]'
PR_THREE='[
  {"number":99011,"title":"feat(flags): first fixture","url":"https://github.com/PostHog/posthog/pull/99011","repo":"PostHog/posthog","author":"team-dev","user_review_state":null},
  {"number":99012,"title":"feat(flags): second fixture","url":"https://github.com/PostHog/posthog/pull/99012","repo":"PostHog/posthog","author":"team-dev","user_review_state":null},
  {"number":99013,"title":"feat(flags): third fixture","url":"https://github.com/PostHog/posthog/pull/99013","repo":"PostHog/posthog","author":"team-dev","user_review_state":null}
]'

case_number=0
STATE_CASE=""
start_case() {
  case_number=$((case_number + 1))
  STATE_CASE="$TESTTMP/state-${case_number}"
  mkdir -p "$STATE_CASE"
  : > "$CODEX_LOG"
  : > "$GH_LOG"
}

run_runner() {
  local state_dir="$1" input="$2"
  shift 2
  printf '%s\n' "$input" | run_bounded 20 env \
    HOME="$FAKE_HOME" PATH="$SHIM_PATH" GH_LOG="$GH_LOG" \
    GH_AUTO_FIXTURE="${GH_AUTO_FIXTURE:-false}" \
    CODEX_LOG="$CODEX_LOG" CODEX_FAIL_FIRST="${CODEX_FAIL_FIRST:-false}" \
    CODEX_RATE_LIMIT="${CODEX_RATE_LIMIT:-false}" \
    CODEX_AUTH_FAIL="${CODEX_AUTH_FAIL:-false}" \
    CLAUDE_RATE_LIMIT="${CLAUDE_RATE_LIMIT:-false}" \
    CLAUDE_RATE_LIMIT_TEXT="${CLAUDE_RATE_LIMIT_TEXT:-false}" \
    RUN_PR_REVIEWS_STATE_DIR="$state_dir" "$BASH4" "$BIN" "$@"
}

codex_log_has_pair() {
  local option="$1" value="$2"
  awk -v option="<$option>" -v value="<$value>" '
    $0 == option {
      if ((getline next_line) > 0 && next_line == value) found = 1
    }
    END { exit !found }
  ' "$CODEX_LOG"
}

start_case
run_runner "$STATE_CASE" "$PR_ONE" --engine codex --max-prs 1 --delay 0 >/dev/null
assert "Codex uses the non-interactive exec command" grep -qx '<exec>' "$CODEX_LOG"
assert "Codex streams machine-readable JSONL" grep -qx '<--json>' "$CODEX_LOG"
assert "Codex does not persist an unattended task" grep -qx '<--ephemeral>' "$CODEX_LOG"
assert "Codex uses the workspace-write sandbox" grep -qx '<workspace-write>' "$CODEX_LOG"
assert "Codex routes any approval request through automatic safety review" \
  grep -qx '<--approve-for-me>' "$CODEX_LOG"
assert "Codex accepts an isolated non-repository working directory" \
  grep -qx '<--skip-git-repo-check>' "$CODEX_LOG"
assert "Codex permits the review skill's session state to be written" \
  codex_log_has_pair --add-dir "$FAKE_HOME/.agents/skills/review-code/.sessions"
assert "Codex permits review worktrees to be created" \
  codex_log_has_pair --add-dir "$FAKE_HOME/.agents/skills/review-code/.worktrees"
assert "Codex permits persistent review files to be written" \
  codex_log_has_pair --add-dir "$FAKE_HOME/.agents/skills/review-code/.reviews"
assert "Codex permits the current review output to be written" \
  codex_log_has_pair --add-dir "$FAKE_HOME/dev/ai/reviews/PostHog-posthog"
assert "Codex runs from the isolated review output directory" \
  codex_log_has_pair -C "$FAKE_HOME/dev/ai/reviews/PostHog-posthog"
assert_not "Codex cannot write the whole installed review skill" \
  grep -qxF "<$FAKE_HOME/.agents/skills/review-code>" "$CODEX_LOG"
assert_not "Codex cannot write the live dotfiles checkout" \
  grep -qxF "<$FAKE_HOME/.dotfiles>" "$CODEX_LOG"
# shellcheck disable=SC2016 # Codex skill prompts intentionally start with a literal dollar sign.
assert "Codex receives the review-code skill prompt" \
  grep -qxF '<$review-code https://github.com/PostHog/posthog/pull/99011 --force --draft>' "$CODEX_LOG"

review_file="$FAKE_HOME/dev/ai/reviews/PostHog-posthog/pr-99011-$(date +%Y%m%d).md"
assert "the Codex agent message is extracted from JSONL into the review artifact" \
  grep -qF 'Codex fixture review result' "$review_file"
assert "the complete multiline Codex message is preserved in the review artifact" \
  grep -qF 'Second fixture line' "$review_file"
assert "the Codex review artifact preserves input-token usage" \
  grep -Eqi 'input[^0-9]*101' "$review_file"
assert "the Codex review artifact preserves output-token usage" \
  grep -Eqi 'output[^0-9]*23' "$review_file"

start_case
CODEX_FAIL_FIRST=true run_runner "$STATE_CASE" "$PR_THREE" \
  --engine codex --max-prs 1 --daily-max-prs 2 --delay 0 >/dev/null || true
run_runner "$STATE_CASE" "$PR_THREE" \
  --engine codex --max-prs 1 --daily-max-prs 2 --delay 0 >/dev/null
run_runner "$STATE_CASE" "$PR_THREE" \
  --engine codex --max-prs 1 --daily-max-prs 2 --delay 0 >/dev/null
assert "--daily-max-prs stops after two attempted Codex reviews" \
  test "$(grep -c '^<exec>$' "$CODEX_LOG")" -eq 2
assert "a failed review consumes the daily safety budget" \
  jq -e '.failed | map(.url) | index("https://github.com/PostHog/posthog/pull/99011") != null' \
    "$STATE_CASE/session-$(date +%Y-%m-%d).json" >/dev/null
assert_not "the daily cap leaves the third PR for a later day" \
  grep -qF 'https://github.com/PostHog/posthog/pull/99013' "$CODEX_LOG"

start_case
CODEX_RATE_LIMIT=true run_runner "$STATE_CASE" "$PR_THREE" \
  --engine codex --delay 0 >/dev/null || true
assert "Codex's usage-limit wording stops the session after one attempt" \
  test "$(grep -c '^<exec>$' "$CODEX_LOG")" -eq 1
assert "a Codex usage limit is recorded as an engine failure" \
  jq -e '.failed[0].reason == "rate_limited"' \
    "$STATE_CASE/session-$(date +%Y-%m-%d).json" >/dev/null
assert_not "a Codex usage limit does not count against the PR failure ledger" \
  jq -e '.prs | has("https://github.com/PostHog/posthog/pull/99011")' \
    "$STATE_CASE/pr-failures.json" >/dev/null

start_case
CODEX_AUTH_FAIL=true run_runner "$STATE_CASE" "$PR_ONE" \
  --engine codex --delay 0 >/dev/null || true
assert "a Codex authentication failure is recorded as an engine failure" \
  jq -e '.failed[0].reason == "auth_failed"' \
    "$STATE_CASE/session-$(date +%Y-%m-%d).json" >/dev/null
assert_not "a Codex authentication failure does not count against the PR failure ledger" \
  jq -e '.prs | has("https://github.com/PostHog/posthog/pull/99011")' \
    "$STATE_CASE/pr-failures.json" >/dev/null

start_case
out=$(GH_AUTO_FIXTURE=true run_runner "$STATE_CASE" '[]' --auto --engine codex \
  --author-team team-feature-flags --dry-run)
assert "--auto keeps a PR authored by the requested team" \
  grep -qF 'https://github.com/PostHog/posthog/pull/99021' <<< "$out"
assert_not "--auto excludes an outside-team PR at the runner boundary" \
  grep -qF 'https://github.com/PostHog/posthog/pull/99022' <<< "$out"

start_case
out=$(run_runner "$STATE_CASE" "$PR_ONE" --dry-run --max-prs 1 --delay 0)
assert "Claude remains the default engine for manual compatibility" \
  grep -qF 'Would run: claude -p "/review-code https://github.com/PostHog/posthog/pull/99011 --force --draft"' <<< "$out"

start_case
CLAUDE_RATE_LIMIT_TEXT=true run_runner "$STATE_CASE" "$PR_ONE" \
  --engine claude --max-prs 1 --delay 0 >/dev/null
assert "successful Claude prose about rate limits remains successful" \
  jq -e '.reviewed | map(.url) | index("https://github.com/PostHog/posthog/pull/99011") != null' \
    "$STATE_CASE/session-$(date +%Y-%m-%d).json" >/dev/null

start_case
CLAUDE_RATE_LIMIT=true run_runner "$STATE_CASE" "$PR_ONE" \
  --engine claude --max-prs 1 --delay 0 >/dev/null || true
assert "Claude's shipped rate-limit signal still stops the session" \
  jq -e '.failed[0].reason == "rate_limited"' \
    "$STATE_CASE/session-$(date +%Y-%m-%d).json" >/dev/null

plist_has_pair() {
  local option="$1" value="$2"
  awk -v option="$option" -v value="$value" '
    index($0, "<string>" option "</string>") {
      if ((getline next_line) > 0 && index(next_line, "<string>" value "</string>")) found = 1
    }
    END { exit !found }
  ' "$PLIST"
}

assert "the LaunchAgent selects the Codex engine" plist_has_pair --engine codex
assert "the LaunchAgent limits review authors to team-feature-flags" \
  plist_has_pair --author-team team-feature-flags
assert "the LaunchAgent starts at most one PR per hourly tick" \
  plist_has_pair --max-prs 1
assert "the LaunchAgent spends at most two attempts per day" \
  plist_has_pair --daily-max-prs 2
assert "the service wrapper selects the Codex engine" \
  grep -Eq -- 'WORKER_ARGS=.*--engine codex' "$SERVICE"
assert "the service wrapper limits review authors to team-feature-flags" \
  grep -Eq -- 'WORKER_ARGS=.*--author-team team-feature-flags' "$SERVICE"
assert "the service wrapper starts at most one PR per run" \
  grep -Eq -- 'WORKER_ARGS=.*--max-prs 1' "$SERVICE"
assert "the service wrapper spends at most two attempts per day" \
  grep -Eq -- 'WORKER_ARGS=.*--daily-max-prs 2' "$SERVICE"

print_results
