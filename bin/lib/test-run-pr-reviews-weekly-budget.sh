#!/bin/bash
# Tests for the weekly Claude budget guard in run-pr-reviews.sh.
#
# Usage: test-run-pr-reviews-weekly-budget.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

BIN="$(cd "$SCRIPT_DIR/.." && pwd)/run-pr-reviews.sh"
BUDGET_LIB="$SCRIPT_DIR/weekly-budget.sh"

TESTTMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TESTTMP"' EXIT

STATE_DIR="$TESTTMP/helper-state"
PAUSE_FILE="$STATE_DIR/weekly-budget-pause.json"
mkdir -p "$STATE_DIR"

unset RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD
# shellcheck source=bin/lib/weekly-budget.sh
source "$BUDGET_LIB"

future_reset=$(( $(date +%s) + 3600 ))
past_reset=$(( $(date +%s) - 60 ))

# The early event is below the ceiling, so reading the first event instead of the
# last one records no pause.
cat > "$TESTTMP/at-threshold.jsonl" <<JSON
not valid json
{"type":"assistant","message":{"content":[]}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"seven_day":{"utilization":0.50,"resetsAt":$future_reset}}}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","unifiedWindows":{"five_hour":{"utilization":0.12,"resetsAt":$future_reset},"seven_day":{"utilization":0.80,"resetsAt":$future_reset}}}}
{"type":"result","subtype":"success","result":"Review complete"}
JSON

# ── A seven-day event at the default threshold creates a pause ────────────

assert "utilization at the default 0.80 threshold records a pause" \
  record_weekly_budget_pause "$TESTTMP/at-threshold.jsonl"
assert "the pause is written to the review state directory" test -f "$PAUSE_FILE"
assert "the pause records utilization, threshold, and reset epoch" \
  jq -e --argjson reset "$future_reset" '
    .version == 1 and
    .utilization == 0.80 and
    .threshold == 0.80 and
    .resets_at == $reset and
    (.recorded_at | type == "string" and length > 0)
  ' "$PAUSE_FILE" >/dev/null

pause_reason=""
pause_rc=0
pause_reason=$(weekly_budget_pause_active) || pause_rc=$?
assert "a pause remains active before its reset time" test "$pause_rc" -eq 0
assert "an active pause quotes the usage and the limit" \
  grep -qF 'weekly Claude usage is 80%, at or above the 80% review limit' <<< "$pause_reason"
assert "an active pause renders the reset time, not a bare epoch" \
  grep -qE "reviews resume after [A-Z][a-z]+day [0-9]{4}-[0-9]{2}-[0-9]{2}" <<< "$pause_reason"

# ── Expired pause state is removed and no longer blocks work ──────────────

cat > "$PAUSE_FILE" <<JSON
{"version":1,"utilization":0.80,"threshold":0.80,"resets_at":$past_reset,"recorded_at":"2026-08-25T00:00:00Z"}
JSON

assert_not "an expired pause is inactive" weekly_budget_pause_active
assert_not "checking an expired pause removes its state file" test -e "$PAUSE_FILE"

# ── Missing and malformed rate-limit data does not pause ──────────────────

rm -f "$PAUSE_FILE"
cat > "$TESTTMP/missing-weekly-window.jsonl" <<'JSON'
not valid json
{"type":"assistant","message":{"content":[]}}
{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","unifiedWindows":{"five_hour":{"utilization":0.99,"resetsAt":1999999999}}}}
{"type":"result","subtype":"success","result":"Review complete"}
JSON

assert_not "a rate-limit event without a seven-day window does not pause" \
  record_weekly_budget_pause "$TESTTMP/missing-weekly-window.jsonl"
assert_not "a missing seven-day window leaves no pause file" test -e "$PAUSE_FILE"

cat > "$TESTTMP/malformed-weekly-window.jsonl" <<'JSON'
{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":"high","resetsAt":null}}}}
{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.95}}}}
JSON

assert_not "malformed seven-day windows do not pause" \
  record_weekly_budget_pause "$TESTTMP/malformed-weekly-window.jsonl"
assert_not "malformed events leave no pause file" test -e "$PAUSE_FILE"

# ── The configured threshold overrides the 0.80 default ───────────────────

cat > "$TESTTMP/below-override.jsonl" <<JSON
{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.85,"resetsAt":$future_reset}}}}
JSON

override_state="$TESTTMP/override-state"
mkdir -p "$override_state"
override_rc=0
env STATE_DIR="$override_state" RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD=0.90 \
  bash -c 'source "$1"; record_weekly_budget_pause "$2"' \
  _ "$BUDGET_LIB" "$TESTTMP/below-override.jsonl" || override_rc=$?
assert "utilization below the configured threshold returns nonzero" \
  test "$override_rc" -ne 0
assert_not "utilization below the configured threshold does not pause" \
  test -e "$override_state/weekly-budget-pause.json"

# ── A configured threshold also pauses, and is recorded separately ────────

cat > "$TESTTMP/above-override.jsonl" <<JSON
{"type":"rate_limit_event","rate_limit_info":{"unifiedWindows":{"seven_day":{"utilization":0.95,"resetsAt":$future_reset}}}}
JSON

above_state="$TESTTMP/above-override-state"
mkdir -p "$above_state"
assert "utilization above the configured threshold records a pause" \
  env STATE_DIR="$above_state" RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD=0.90 \
  bash -c 'source "$1"; record_weekly_budget_pause "$2"' \
  _ "$BUDGET_LIB" "$TESTTMP/above-override.jsonl"
assert "utilization and threshold are recorded as separate values" \
  jq -e '.utilization == 0.95 and .threshold == 0.90' \
  "$above_state/weekly-budget-pause.json" >/dev/null

# ── Raising the ceiling releases an active pause ──────────────────────────

release_state="$TESTTMP/release-state"
mkdir -p "$release_state"
cat > "$release_state/weekly-budget-pause.json" <<JSON
{"version":1,"utilization":0.82,"threshold":0.80,"resets_at":$future_reset,"recorded_at":"2026-08-25T00:00:00Z"}
JSON

assert "a pause recorded under the default ceiling is active" \
  env STATE_DIR="$release_state" \
  bash -c 'source "$1"; weekly_budget_pause_active >/dev/null' _ "$BUDGET_LIB"
assert_not "raising the ceiling above the recorded usage releases the pause" \
  env STATE_DIR="$release_state" RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD=0.95 \
  bash -c 'source "$1"; weekly_budget_pause_active >/dev/null' _ "$BUDGET_LIB"
assert_not "releasing a pause removes its state file" \
  test -e "$release_state/weekly-budget-pause.json"

# ── The ceiling must be a fraction, so percent typos are rejected ─────────

for bad_threshold in 0 80 1.5 -0.5 not-a-number; do
  assert_not "a ceiling of ${bad_threshold} is rejected" \
    env RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD="$bad_threshold" \
    bash -c 'source "$1"; weekly_budget_threshold_valid' _ "$BUDGET_LIB"
done

for good_threshold in 0.5 0.80 1; do
  assert "a ceiling of ${good_threshold} is accepted" \
    env RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD="$good_threshold" \
    bash -c 'source "$1"; weekly_budget_threshold_valid' _ "$BUDGET_LIB"
done

# ── Runner wiring: a Claude event persists the pause for later ticks ──────

FAKE_HOME="$TESTTMP/home"
RUNNER_STATE="$TESTTMP/runner-state"
SHIM_DIR="$TESTTMP/bin"
TOOL_LOG="$TESTTMP/tools.log"
mkdir -p "$FAKE_HOME" "$RUNNER_STATE" "$SHIM_DIR"

cat > "$SHIM_DIR/gh" <<'SHIM'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$TOOL_LOG"
if [[ "${1-}" == "auth" && "${2-}" == "status" ]]; then
  exit 0
fi
if [[ "${1-}" == "api" && "${2-}" == "user" ]]; then
  echo "me"
  exit 0
fi
case "${2-}" in
  */reviews) echo '[]' ;;
  */comments) echo '[{"user":{"login":"me"},"created_at":"2999-01-01T00:00:00Z"}]' ;;
  *) echo '[]' ;;
esac
SHIM

cat > "$SHIM_DIR/caffeinate" <<'SHIM'
#!/bin/bash
[[ "${1-}" == "-i" ]] && shift
exec "$@"
SHIM

cat > "$SHIM_DIR/timeout" <<'SHIM'
#!/bin/bash
while [[ "${1-}" == --* ]]; do shift; done
shift
exec "$@"
SHIM

cat > "$SHIM_DIR/claude" <<'SHIM'
#!/bin/bash
printf 'claude %s\n' "$*" >> "$TOOL_LOG"
printf '{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","unifiedWindows":{"seven_day":{"utilization":0.80,"resetsAt":%s}}}}\n' "$WEEKLY_RESET"
echo '{"type":"result","subtype":"success","result":"Review complete"}'
SHIM

chmod +x "$SHIM_DIR/gh" "$SHIM_DIR/caffeinate" "$SHIM_DIR/timeout" "$SHIM_DIR/claude"

cat > "$TESTTMP/prs.json" <<'JSON'
[
  {"url":"https://github.com/PostHog/posthog/pull/99003","number":99003,"title":"feat(flags): weekly budget fixture","repo":"PostHog/posthog","author":"dev-one","user_review_state":"NONE"},
  {"url":"https://github.com/PostHog/posthog/pull/99004","number":99004,"title":"feat(flags): must wait for the weekly reset","repo":"PostHog/posthog","author":"dev-two","user_review_state":"NONE"}
]
JSON

: > "$TOOL_LOG"
runner_rc=0
run_bounded 20 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" WEEKLY_RESET="$future_reset" \
  RUN_PR_REVIEWS_STATE_DIR="$RUNNER_STATE" \
  "$BIN" --max-prs 2 --delay 0 < "$TESTTMP/prs.json" >/dev/null || runner_rc=$?
assert "a review carrying a weekly rate-limit event completes" test "$runner_rc" -eq 0
assert "the runner invoked Claude for the fixture review" grep -q '^claude ' "$TOOL_LOG"
assert "the weekly threshold stops the session before the second queued review" \
  test "$(grep -c '^claude ' "$TOOL_LOG")" -eq 1
assert "the runner persists the weekly pause from Claude's transcript" \
  jq -e --argjson reset "$future_reset" \
  '.utilization == 0.80 and .threshold == 0.80 and .resets_at == $reset' \
  "$RUNNER_STATE/weekly-budget-pause.json" >/dev/null
assert "the session records why the run stopped" \
  jq -e '[.errors[].message] | index("weekly Claude budget threshold reached") != null' \
  "$RUNNER_STATE/session-$(date +%Y-%m-%d).json" >/dev/null
assert "the reviewed PR is recorded so the reset does not review it twice" \
  jq -e '[.reviewed[].url] | index("https://github.com/PostHog/posthog/pull/99003") != null' \
  "$RUNNER_STATE/session-$(date +%Y-%m-%d).json" >/dev/null

# ── Later scheduled ticks stop before prerequisites and discovery ─────────

BLACKBOX_STATE="$TESTTMP/blackbox-state"
mkdir -p "$BLACKBOX_STATE"
cat > "$BLACKBOX_STATE/weekly-budget-pause.json" <<JSON
{"version":1,"utilization":0.80,"threshold":0.80,"resets_at":$future_reset,"recorded_at":"2026-08-25T00:00:00Z"}
JSON

: > "$TOOL_LOG"
active_rc=0
run_bounded 10 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  "$BIN" --auto >/dev/null || active_rc=$?
assert "a scheduled tick exits successfully while the weekly pause is active" \
  test "$active_rc" -eq 0
assert_not "an active weekly pause stops before prerequisite and discovery tools" \
  test -s "$TOOL_LOG"

# An expired pause must not suppress normal startup. Make gh auth fail after it
# is invoked so the test stops before real discovery, while proving the runner
# got past the weekly-budget guard.
cat > "$BLACKBOX_STATE/weekly-budget-pause.json" <<JSON
{"version":1,"utilization":0.80,"threshold":0.80,"resets_at":$past_reset,"recorded_at":"2026-08-25T00:00:00Z"}
JSON
cp "$SHIM_DIR/gh" "$TESTTMP/gh.working"
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$TOOL_LOG"
exit 97
SHIM
chmod +x "$SHIM_DIR/gh"

: > "$TOOL_LOG"
expired_rc=0
run_bounded 10 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  "$BIN" --auto >/dev/null || expired_rc=$?
assert "an expired pause lets normal startup continue" test "$expired_rc" -eq 1
assert "normal startup reaches prerequisite tools after the reset" test -s "$TOOL_LOG"
assert_not "normal startup clears the expired pause" \
  test -e "$BLACKBOX_STATE/weekly-budget-pause.json"

cp "$TESTTMP/gh.working" "$SHIM_DIR/gh"

# ── A dry run spends no quota, so an active pause must not stop it ────────

cat > "$BLACKBOX_STATE/weekly-budget-pause.json" <<JSON
{"version":1,"utilization":0.80,"threshold":0.80,"resets_at":$future_reset,"recorded_at":"2026-08-25T00:00:00Z"}
JSON

: > "$TOOL_LOG"
dry_rc=0
dry_out=$(run_bounded 10 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  "$BIN" --dry-run --max-prs 1 --delay 0 < "$TESTTMP/prs.json") || dry_rc=$?
assert "a dry run succeeds while the weekly pause is active" test "$dry_rc" -eq 0
assert "a dry run still lists the queue while the weekly pause is active" \
  grep -q '99003' <<< "$dry_out"
assert_not "a dry run does not invoke Claude" grep -q '^claude ' "$TOOL_LOG"
assert "an active pause survives a dry run" \
  test -e "$BLACKBOX_STATE/weekly-budget-pause.json"

# --auto is the only mode the pause skips, so the dry-run exemption is only
# reachable, and only testable, in combination with it.
: > "$TOOL_LOG"
run_bounded 10 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  "$BIN" --auto --dry-run >/dev/null || true
assert "an automatic dry run starts up despite the weekly pause" \
  test -s "$TOOL_LOG"
assert_not "an automatic dry run does not invoke Claude" \
  grep -q '^claude ' "$TOOL_LOG"

# ── Only --auto is unattended, so only it skips a whole session ───────────

: > "$TOOL_LOG"
manual_rc=0
run_bounded 20 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" WEEKLY_RESET="$future_reset" \
  RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  "$BIN" --max-prs 1 --delay 0 < "$TESTTMP/prs.json" >/dev/null || manual_rc=$?
assert "a run you start yourself succeeds while the weekly pause is active" \
  test "$manual_rc" -eq 0
assert "a run you start yourself still reviews while the weekly pause is active" \
  grep -q '^claude ' "$TOOL_LOG"

# ── The pause reports Claude quota, so it must not stop a codex run ───────

cat > "$SHIM_DIR/codex" <<'SHIM'
#!/bin/bash
printf 'codex %s\n' "$*" >> "$TOOL_LOG"
[[ "${1-}" == "login" ]] && exit 0
echo '{"type":"item.completed","item":{"type":"agent_message","text":"Review complete"}}'
SHIM
chmod +x "$SHIM_DIR/codex"

# --auto is the only mode the pause skips, so the engine gate is only
# reachable, and only testable, in combination with it.
: > "$TOOL_LOG"
run_bounded 20 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  "$BIN" --auto --engine codex --max-prs 1 --delay 0 >/dev/null || true
assert "an automatic codex run starts up despite a Claude weekly pause" \
  test -s "$TOOL_LOG"
assert "a Claude pause survives an automatic codex run" \
  test -e "$BLACKBOX_STATE/weekly-budget-pause.json"

rm -f "$BLACKBOX_STATE/weekly-budget-pause.json"
cat > "$SHIM_DIR/gh" <<'SHIM'
#!/bin/bash
printf 'gh %s\n' "$*" >> "$TOOL_LOG"
exit 97
SHIM
chmod +x "$SHIM_DIR/gh"

# A typo in the ceiling must fail closed before a scheduled run reaches GitHub
# or Claude. Otherwise the guard silently disappears until someone notices.
: > "$TOOL_LOG"
invalid_rc=0
run_bounded 10 env HOME="$FAKE_HOME" PATH="$SHIM_DIR:$PATH" \
  TOOL_LOG="$TOOL_LOG" RUN_PR_REVIEWS_STATE_DIR="$BLACKBOX_STATE" \
  RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD=not-a-number \
  "$BIN" --auto >/dev/null || invalid_rc=$?
assert "an invalid weekly threshold fails startup" test "$invalid_rc" -eq 1
assert_not "an invalid weekly threshold fails before prerequisite and discovery tools" \
  test -s "$TOOL_LOG"

print_results
