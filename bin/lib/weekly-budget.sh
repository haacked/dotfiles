#!/usr/bin/env bash
# Persist Claude's seven-day usage warning so unattended review runs leave quota
# for interactive work until the reported window resets.

WEEKLY_BUDGET_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/fs.sh
source "${WEEKLY_BUDGET_LIB_DIR}/fs.sh"

weekly_budget_pause_file() {
  printf '%s/weekly-budget-pause.json\n' "$STATE_DIR"
}

weekly_budget_threshold() {
  printf '%s\n' "${RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD:-0.80}"
}

weekly_budget_threshold_valid() {
  local threshold
  threshold=$(weekly_budget_threshold)
  jq -en --arg threshold "$threshold" \
    '($threshold | tonumber?) as $value | $value != null and $value > 0 and $value <= 1' \
    >/dev/null
}

record_weekly_budget_pause() {
  local stream_file="$1"
  local weekly payload

  # A review emits several of these. Only the last one reports current usage.
  weekly=$(jq -R -c '
    fromjson?
    | select(.type == "rate_limit_event")
    | .rate_limit_info.unifiedWindows.seven_day?
    | select((.utilization | type) == "number")
    | select((.resetsAt | type) == "number")
  ' "$stream_file" | tail -n 1)

  [[ -n "$weekly" ]] || return 1

  payload=$(jq -c \
    --argjson threshold "$(weekly_budget_threshold)" \
    --argjson now "$(date +%s)" \
    --arg recorded_at "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" '
      select(.utilization >= $threshold and .resetsAt > $now)
      | {
          version: 1,
          utilization: .utilization,
          threshold: $threshold,
          resets_at: .resetsAt,
          recorded_at: $recorded_at
        }
    ' <<< "$weekly")

  [[ -n "$payload" ]] || return 1

  atomic_write "$(weekly_budget_pause_file)" <<< "$payload"
}

# Compares the recorded usage against the threshold in force now, so raising
# RUN_PR_REVIEWS_WEEKLY_BUDGET_THRESHOLD releases a pause. Deletes the pause file
# when it is expired, malformed, or no longer reaches that threshold.
weekly_budget_pause_active() {
  local pause_file state resets_at utilization_percent threshold_percent reset_display

  pause_file=$(weekly_budget_pause_file)
  [[ -f "$pause_file" ]] || return 1

  state=$(jq -r \
    --argjson now "$(date +%s)" \
    --argjson threshold "$(weekly_budget_threshold)" '
      select(.version == 1)
      | select((.utilization | type) == "number")
      | select((.resets_at | type) == "number")
      | select(.resets_at > $now)
      | select(.utilization >= $threshold)
      | [(.utilization * 100 | round), ($threshold * 100 | round), .resets_at]
      | @tsv
    ' "$pause_file" 2>/dev/null) || state=""

  if [[ -z "$state" ]]; then
    rm -f "$pause_file"
    return 1
  fi

  IFS=$'\t' read -r utilization_percent threshold_percent resets_at <<< "$state"
  # date -r takes an epoch on BSD and a filename on GNU, so try both.
  reset_display=$(date -r "$resets_at" '+%A %Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || date -d "@$resets_at" '+%A %Y-%m-%d %H:%M:%S %Z' 2>/dev/null \
    || printf '%s' "$resets_at")
  printf 'weekly Claude usage is %s%%, at or above the %s%% review limit; reviews resume after %s\n' \
    "$utilization_percent" "$threshold_percent" "$reset_display"
}
