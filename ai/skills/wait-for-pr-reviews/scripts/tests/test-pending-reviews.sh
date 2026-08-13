#!/usr/bin/env bash
# Tests for pending-reviews.jq, the mid-review verdict.
#
# The verdict decides which PR reviewers are still mid-review: the ReviewHog
# label versus requested bot reviewers. Completion is read from machine
# markers and timestamps - a marker in a review/comment body plus an ordering
# against the label event - never from the bot's prose.
#
# Usage: test-pending-reviews.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDICT_JQ="${SCRIPT_DIR}/../helpers/pending-reviews.jq"

passes=0
failures=0

# input '<field overrides json>' -> full verdict input with sane defaults
input() {
    jq -n --argjson over "$1" '{
        labels: [], timeline: [], reviews: [], comments: [], requested_users: []
    } + $over'
}

# assert '<description>' '<overrides json>' '<jq expression>' '<expected>'
# expression is a raw jq filter (not a dotted getpath) so array-shaped output
# like `.pending | length` or `.pending[0].reviewer` can be asserted directly.
# A verdict crash is reported as a FAIL for that one case (with jq's error text)
# instead of aborting the whole suite via errexit.
assert() {
    local description="$1" over="$2" expr="$3" expected="$4"
    local actual
    if ! actual=$({ input "${over}" | jq -f "${VERDICT_JQ}" | jq -r "${expr} | tostring"; } 2>&1); then
        echo "FAIL: ${description}"
        echo "  verdict crashed: ${actual}"
        failures=$((failures + 1))
        return 0
    fi
    if [[ "${actual}" == "${expected}" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        echo "  ${expr}: expected '${expected}', got '${actual}'"
        failures=$((failures + 1))
    fi
}

# labeled_event '<label>' '<created_at>' -> a "labeled" timeline event
labeled_event() {
    jq -c -n --arg l "$1" --arg t "$2" \
        '{event: "labeled", label: $l, reviewer: null, created_at: $t}'
}

# review_requested_event '<reviewer>' '<created_at>' -> a "review_requested" timeline event
review_requested_event() {
    jq -c -n --arg r "$1" --arg t "$2" \
        '{event: "review_requested", label: null, reviewer: $r, created_at: $t}'
}

# review '<login>' '<type>' '<body>' '<submitted_at or "null">' -> a review object
review() {
    jq -c -n --arg l "$1" --arg ty "$2" --arg b "$3" --arg s "$4" \
        '{login: $l, type: $ty, body: $b,
          submitted_at: ($s | if . == "null" then null else . end)}'
}

# comment '<login>' '<type>' '<body>' '<created_at>' '<updated_at>' -> an issue comment object
comment() {
    jq -c -n --arg l "$1" --arg ty "$2" --arg b "$3" --arg c "$4" --arg u "$5" \
        '{login: $l, type: $ty, body: $b, created_at: $c, updated_at: $u}'
}

REVIEWHOG_MARKER='# ReviewHog Report
<!-- reviewhog:published:abc -->'

T1="2026-08-12T10:00:00Z"
T2="2026-08-12T11:00:00Z"
T3="2026-08-12T12:00:00Z"

# ── Empty input ──────────────────────────────────────────────────────────────

assert "empty everything -> no pending, no warnings" \
    '{}' '.pending | length' "0"

assert "empty everything -> no warnings" \
    '{}' '.warnings | length' "0"

# ── Requested-reviewer entries ───────────────────────────────────────────────

assert "bot requested reviewer -> one pending entry" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        '{requested_users: [$u]}')" \
    '.pending | length' "1"

assert "bot requested reviewer -> signal is requested_reviewer" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        '{requested_users: [$u]}')" \
    '.pending[0].signal' "requested_reviewer"

assert "bot requested reviewer -> reviewer login preserved" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        '{requested_users: [$u]}')" \
    '.pending[0].reviewer' "greptile-apps[bot]"

assert "copilot login with User type -> included via login match" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "copilot-pull-request-reviewer[bot]", type: "User"}')" \
        '{requested_users: [$u]}')" \
    '.pending | length' "1"

assert "human handle containing copilot -> excluded" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "copilot-fan", type: "User"}')" \
        '{requested_users: [$u]}')" \
    '.pending | length' "0"

assert "requested human -> excluded" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "haacked", type: "User"}')" \
        '{requested_users: [$u]}')" \
    '.pending | length' "0"

# ── ReviewHog label: basic pending ──────────────────────────────────────────

assert "label present + labeled event, no reviews/comments -> pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        '{labels: ["reviewhog"], timeline: [$e]}')" \
    '.pending | length' "1"

assert "label present + labeled event, no reviews/comments -> since is label time" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        '{labels: ["reviewhog"], timeline: [$e]}')" \
    '.pending[0].since' "${T1}"

# ── ReviewHog completion via marker review ──────────────────────────────────

assert "marker review after label -> not pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" \
        '{labels: ["reviewhog"], timeline: [$e], reviews: [$r]}')" \
    '.pending | length' "0"

assert "label re-applied after marker review -> pending again" \
    "$(jq -n --argjson e1 "$(labeled_event "reviewhog" "${T1}")" \
        --argjson e2 "$(labeled_event "reviewhog" "${T3}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" \
        '{labels: ["reviewhog"], timeline: [$e1, $e2], reviews: [$r]}')" \
    '.pending | length' "1"

assert "label re-applied after marker review -> since is the later label time" \
    "$(jq -n --argjson e1 "$(labeled_event "reviewhog" "${T1}")" \
        --argjson e2 "$(labeled_event "reviewhog" "${T3}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" \
        '{labels: ["reviewhog"], timeline: [$e1, $e2], reviews: [$r]}')" \
    '.pending[0].since' "${T3}"

# ── posthog[bot] activity without the marker is not ReviewHog ──────────────

assert "posthog[bot] review WITHOUT marker after label -> still pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "just a plain review, no marker here" "${T2}")" \
        '{labels: ["reviewhog"], timeline: [$e], reviews: [$r]}')" \
    '.pending | length' "1"

# ── The marker only counts from posthog[bot]: a bot quoting a report is not a
#    completion ────────────────────────────────────────────────────────────────

assert "another bot's review quoting the marker after label -> still pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson r "$(review "copilot-pull-request-reviewer[bot]" "Bot" "quoting: ${REVIEWHOG_MARKER}" "${T2}")" \
        '{labels: ["reviewhog"], timeline: [$e], reviews: [$r]}')" \
    '.pending | length' "1"

# ── ReviewHog completion via marker comment ─────────────────────────────────

assert "marker comment updated after label and after its own creation -> not pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz -->" "${T1}" "${T3}")" \
        '{labels: ["reviewhog"], timeline: [$e], comments: [$c]}')" \
    '.pending | length' "0"

assert "fresh placeholder comment (updated_at == created_at) -> still pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz -->" "${T3}" "${T3}")" \
        '{labels: ["reviewhog"], timeline: [$e], comments: [$c]}')" \
    '.pending | length' "1"

# ── Label removed / undatable ───────────────────────────────────────────────

assert "label absent but labeled event exists -> not pending (label removed)" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        '{labels: [], timeline: [$e]}')" \
    '.pending | length' "0"

assert "label present, no matching labeled event -> not pending" \
    '{"labels": ["reviewhog"], "timeline": []}' '.pending | length' "0"

assert "label present, no matching labeled event -> one warning" \
    '{"labels": ["reviewhog"], "timeline": []}' '.warnings | length' "1"

# ── Login-pattern completion path ───────────────────────────────────────────

assert "reviewhog[bot] review without marker after label -> not pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson r "$(review "reviewhog[bot]" "Bot" "no marker here" "${T2}")" \
        '{labels: ["reviewhog"], timeline: [$e], reviews: [$r]}')" \
    '.pending | length' "0"

# ── null submitted_at is ignored ────────────────────────────────────────────

assert "marker review with submitted_at null -> ignored, still pending" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "null")" \
        '{labels: ["reviewhog"], timeline: [$e], reviews: [$r]}')" \
    '.pending | length' "1"

# ── Only other labels' events exist -> same as undatable ───────────────────

assert "labeled events only for other labels -> not pending" \
    "$(jq -n --argjson e "$(labeled_event "bug" "${T1}")" \
        '{labels: ["reviewhog"], timeline: [$e]}')" \
    '.pending | length' "0"

assert "labeled events only for other labels -> one warning" \
    "$(jq -n --argjson e "$(labeled_event "bug" "${T1}")" \
        '{labels: ["reviewhog"], timeline: [$e]}')" \
    '.warnings | length' "1"

# ── Requested-reviewer since resolution ─────────────────────────────────────

assert "requested reviewer with matching review_requested event -> since equals it" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        --argjson e "$(review_requested_event "greptile-apps[bot]" "${T1}")" \
        '{requested_users: [$u], timeline: [$e]}')" \
    '.pending[0].since' "${T1}"

assert "requested reviewer with no matching event -> since is null" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        '{requested_users: [$u]}')" \
    '.pending[0].since' "null"

# ── Case-insensitivity ───────────────────────────────────────────────────────

assert "case-insensitive label and event name -> still detected as pending" \
    "$(jq -n --argjson e "$(labeled_event "ReviewHog" "${T1}")" \
        '{labels: ["ReviewHog"], timeline: [$e]}')" \
    '.pending | length' "1"

# ── Malformed input tolerance ────────────────────────────────────────────────

assert "null label name -> no crash, not pending" \
    '{"labels": [null]}' '.pending | length' "0"

# ── Output ordering ──────────────────────────────────────────────────────────
# ReviewHog first, then requested-reviewer entries in input order.

assert "ReviewHog entry sorts before requested-reviewer entries" \
    "$(jq -n --argjson e "$(labeled_event "reviewhog" "${T1}")" \
        --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        '{labels: ["reviewhog"], timeline: [$e], requested_users: [$u]}')" \
    '.pending[0].reviewer' "reviewhog"

assert "requested-reviewer entries keep input order" \
    "$(jq -n --argjson ua "$(jq -c -n '{login: "aaa-bot[bot]", type: "Bot"}')" \
        --argjson ub "$(jq -c -n '{login: "zzz-bot[bot]", type: "Bot"}')" \
        '{requested_users: [$ua, $ub]}')" \
    '[.pending[].reviewer]' '["aaa-bot[bot]","zzz-bot[bot]"]'

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
