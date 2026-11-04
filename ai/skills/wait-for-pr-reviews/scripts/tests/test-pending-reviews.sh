#!/usr/bin/env bash
# Tests for pending-reviews.jq, the mid-review verdict.
#
# The verdict decides which PR reviewers are still mid-review: a ReviewHog
# trigger comment versus requested bot reviewers. ReviewHog completion uses machine
# markers and timestamps, except an updated status comment remains pending
# while its heading still says "reviewing".
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
        head_sha: "", timeline: [], reviews: [], comments: [], requested_users: []
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

# review_requested_event '<reviewer>' '<created_at>' -> a "review_requested" timeline event
review_requested_event() {
    jq -c -n --arg r "$1" --arg t "$2" \
        '{event: "review_requested", reviewer: $r, created_at: $t}'
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
<!-- reviewhog:published:abc:sha:flash -->'
DEEP_MARKER='# ReviewHog Report
<!-- reviewhog:published:abc:sha:full -->'

# trigger '<body>' '<created_at>' -> a person's trigger comment
trigger() {
    comment "haacked" "User" "$1" "$2" "$2"
}

# with_trigger '<created_at>' ['<extra jq object>'] -> input with one plain trigger
# comment at that time, merged with the extra fields. Extra comments append
# after the trigger.
with_trigger() {
    local extra="${2:-"{}"}"
    jq -n --argjson t "$(trigger "@posthog review" "$1")" --argjson x "${extra}" \
        '$x + {comments: ([$t] + ($x.comments // []))}'
}

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

# The wrapper's projection turns a missing login into "", never null; a raw
# null is tolerated (null reviewer in the entry) rather than crashing.
assert "null-login bot entry -> tolerated, still pending" \
    '{"requested_users": [{"login": null, "type": "Bot"}]}' \
    '.pending | length' "1"

# ── ReviewHog trigger comment: basic pending ────────────────────────────────

assert "trigger comment, no reviews/comments -> pending" \
    "$(with_trigger "${T1}")" '.pending | length' "1"

assert "trigger comment -> signal is comment" \
    "$(with_trigger "${T1}")" '.pending[0].signal' "comment"

assert "trigger comment -> since is the comment time" \
    "$(with_trigger "${T1}")" '.pending[0].since' "${T1}"

assert "deep trigger comment -> pending" \
    "$(jq -n --argjson t "$(trigger "@posthog review --deep" "${T1}")" '{comments: [$t]}')" \
    '.pending | length' "1"

assert "trigger with leading whitespace and capitals -> pending" \
    "$(jq -n --argjson t "$(trigger "  @PostHog Review --deep" "${T1}")" '{comments: [$t]}')" \
    '.pending | length' "1"

assert "comment that only mentions the trigger mid-sentence -> not pending" \
    "$(jq -n --argjson t "$(trigger "should I run @posthog review here?" "${T1}")" '{comments: [$t]}')" \
    '.pending | length' "0"

assert "comment starting with a longer word -> not pending" \
    "$(jq -n --argjson t "$(trigger "@posthog reviewers please look" "${T1}")" '{comments: [$t]}')" \
    '.pending | length' "0"

assert "bot comment with the trigger text -> not pending" \
    "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" "@posthog review" "${T1}" "${T1}")" '{comments: [$c]}')" \
    '.pending | length' "0"

# ── ReviewHog completion via marker review ──────────────────────────────────

assert "marker review after trigger -> not pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" '{reviews: [$r]}')")" \
    '.pending | length' "0"

assert "trigger posted again after marker review -> pending again" \
    "$(jq -n --argjson t1 "$(trigger "@posthog review" "${T1}")" \
        --argjson t2 "$(trigger "@posthog review" "${T3}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" \
        '{comments: [$t1, $t2], reviews: [$r]}')" \
    '.pending | length' "1"

assert "trigger posted again after marker review -> since is the later trigger" \
    "$(jq -n --argjson t1 "$(trigger "@posthog review" "${T1}")" \
        --argjson t2 "$(trigger "@posthog review" "${T3}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" \
        '{comments: [$t1, $t2], reviews: [$r]}')" \
    '.pending[0].since' "${T3}"

# ── A --deep trigger needs a Deep review ────────────────────────────────────

assert "Standard review after a deep trigger -> still pending" \
    "$(jq -n --argjson t "$(trigger "@posthog review --deep" "${T1}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" \
        '{comments: [$t], reviews: [$r]}')" \
    '.pending | length' "1"

assert "Deep review after a deep trigger -> not pending" \
    "$(jq -n --argjson t "$(trigger "@posthog review --deep" "${T1}")" \
        --argjson r "$(review "posthog[bot]" "Bot" "${DEEP_MARKER}" "${T2}")" \
        '{comments: [$t], reviews: [$r]}')" \
    '.pending | length' "0"

assert "finished status comment after a deep trigger -> not pending" \
    "$(jq -n --argjson t "$(trigger "@posthog review --deep" "${T1}")" \
        --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz --> Deep review done" "${T2}" "${T3}")" \
        '{comments: [$t, $c]}')" \
    '.pending | length' "0"

# ── A published review of the current head from before the trigger completes it
# ReviewHog answers a trigger at a head it already published a review of in that
# mode without starting a run, so no review lands after the trigger.

HEAD_SHA="1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3"
OTHER_SHA="9e8d7c6b5a4f3e2d1c0b9a8f7e6d5c4b3a2f1e0d"

# before_trigger '<trigger body>' '<review login>' '<review body>' ['<review commit>']
# -> the review at T1 on that commit (HEAD_SHA by default), the trigger at T2, and
# the PR's head at HEAD_SHA
before_trigger() {
    jq -n --argjson t "$(trigger "$1" "${T2}")" \
        --argjson r "$(review "$2" "Bot" "$3" "${T1}")" --arg c "${4:-${HEAD_SHA}}" --arg h "${HEAD_SHA}" \
        '{head_sha: $h, comments: [$t], reviews: [$r + {commit_id: $c}]}'
}

assert "Standard review of the head before a plain trigger -> not pending" \
    "$(before_trigger "@posthog review" "posthog[bot]" "${REVIEWHOG_MARKER}")" \
    '.pending | length' "0"

assert "Standard review of an older head before a plain trigger -> pending" \
    "$(before_trigger "@posthog review" "posthog[bot]" "${REVIEWHOG_MARKER}" "${OTHER_SHA}")" \
    '.pending | length' "1"

assert "Deep review of the head before a plain trigger -> not pending" \
    "$(before_trigger "@posthog review" "posthog[bot]" "${DEEP_MARKER}")" \
    '.pending | length' "0"

assert "Deep review of the head before a deep trigger -> not pending" \
    "$(before_trigger "@posthog review --deep" "posthog[bot]" "${DEEP_MARKER}")" \
    '.pending | length' "0"

assert "Standard review of the head before a deep trigger -> pending" \
    "$(before_trigger "@posthog review --deep" "posthog[bot]" "${REVIEWHOG_MARKER}")" \
    '.pending | length' "1"

# ReviewHog runs a requested round again at a head with only a clean reply, and
# that round can publish findings after the wait ends.
assert "clean reply on the head before a plain trigger -> pending" \
    "$(before_trigger "@posthog review" "posthog[bot]" "No findings. <!-- reviewhog:clean-reply:abc:${HEAD_SHA} -->")" \
    '.pending | length' "1"

assert "large pull request note on the head before a plain trigger -> pending" \
    "$(before_trigger "@posthog review" "posthog[bot]" "<!-- reviewhog:large-pr-note:abc:${HEAD_SHA} -->")" \
    '.pending | length' "1"

assert "another bot's review of the head quoting the marker -> pending" \
    "$(before_trigger "@posthog review" "copilot-pull-request-reviewer[bot]" "${REVIEWHOG_MARKER}")" \
    '.pending | length' "1"

assert "unknown head -> a review from before the trigger does not count" \
    "$(before_trigger "@posthog review" "posthog[bot]" "${REVIEWHOG_MARKER}" "" | jq '.head_sha = ""')" \
    '.pending | length' "1"

# ── posthog[bot] activity without the marker is not ReviewHog ──────────────

assert "posthog[bot] review WITHOUT marker after trigger -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson r "$(review "posthog[bot]" "Bot" "just a plain review, no marker here" "${T2}")" '{reviews: [$r]}')")" \
    '.pending | length' "1"

assert "ReviewHog's acknowledgement reply after trigger -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" "<!-- posthog-github-command:1 --> @haacked PostHog Review is reviewing this pull request." "${T2}" "${T2}")" '{comments: [$c]}')")" \
    '.pending | length' "1"

# ── The marker only counts from posthog[bot]: a bot quoting a report is not a
#    completion ────────────────────────────────────────────────────────────────

assert "another bot's review quoting the marker after trigger -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson r "$(review "copilot-pull-request-reviewer[bot]" "Bot" "quoting: ${REVIEWHOG_MARKER}" "${T2}")" '{reviews: [$r]}')")" \
    '.pending | length' "1"

# ── ReviewHog completion via marker comment ─────────────────────────────────

assert "marker comment updated after trigger and after its own creation -> not pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz -->" "${T1}" "${T3}")" '{comments: [$c]}')")" \
    '.pending | length' "0"

assert "updated marker comment that is still reviewing -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz --> ReviewHog is reviewing (step 3 of 6)" "${T2}" "${T3}")" '{comments: [$c]}')")" \
    '.pending | length' "1"

assert "status comment after a progress edit (Deep · reviewing) -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" '<!-- reviewhog:status:xyz -->
### PostHog Review · Deep · reviewing `eb71424`

| Step | Status | Result |' "${T2}" "${T3}")" '{comments: [$c]}')")" \
    '.pending | length' "1"

assert "status comment edited to its finished heading (Deep · reviewed) -> not pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" '<!-- reviewhog:status:xyz -->
### PostHog Review · Deep · reviewed `eb71424`

Found 2 findings, all below the urgency threshold.' "${T2}" "${T3}")" '{comments: [$c]}')")" \
    '.pending | length' "0"

assert "fresh placeholder comment (updated_at == created_at) -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz -->" "${T3}" "${T3}")" '{comments: [$c]}')")" \
    '.pending | length' "1"

# ── Strict ordering: a timestamp equal to the trigger's is not "after" it ────

assert "marker review submitted at exactly the trigger time -> still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T1}")" '{reviews: [$r]}')")" \
    '.pending | length' "1"

assert "marker comment updated at exactly the trigger time -> still pending" \
    "$(with_trigger "${T2}" "$(jq -n --argjson c "$(comment "posthog[bot]" "Bot" "<!-- reviewhog:status:xyz -->" "${T1}" "${T2}")" '{comments: [$c]}')")" \
    '.pending | length' "1"

# ── Marker reviews with no trigger ──────────────────────────────────────────

assert "Standard review with no trigger comment -> not pending" \
    "$(jq -n --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "${T2}")" '{reviews: [$r]}')" \
    '.pending | length' "0"

# ── Login-pattern completion path ───────────────────────────────────────────

assert "reviewhog[bot] review without marker after trigger -> not pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson r "$(review "reviewhog[bot]" "Bot" "no marker here" "${T2}")" '{reviews: [$r]}')")" \
    '.pending | length' "0"

# ── null timestamps are ignored ─────────────────────────────────────────────

assert "marker review with submitted_at null -> ignored, still pending" \
    "$(with_trigger "${T1}" "$(jq -n --argjson r "$(review "posthog[bot]" "Bot" "${REVIEWHOG_MARKER}" "null")" '{reviews: [$r]}')")" \
    '.pending | length' "1"

assert "trigger comment with created_at null -> ignored, not pending" \
    '{"comments": [{"login": "haacked", "type": "User", "body": "@posthog review", "created_at": null, "updated_at": null}]}' \
    '.pending | length' "0"

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

# GitHub logs Copilot's request under "Copilot" but returns the reviewer node as
# "copilot-pull-request-reviewer"; the join treats the aliases as one reviewer.
assert "copilot requested under an alias login -> since equals the timeline event" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "copilot-pull-request-reviewer", type: "Bot"}')" \
        --argjson e "$(review_requested_event "Copilot" "${T1}")" \
        '{requested_users: [$u], timeline: [$e]}')" \
    '.pending[0].since' "${T1}"

assert "unrelated bot does not borrow another reviewer's request event -> since is null" \
    "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" \
        --argjson e "$(review_requested_event "Copilot" "${T1}")" \
        '{requested_users: [$u], timeline: [$e]}')" \
    '.pending[0].since' "null"

# ── Malformed input tolerance ────────────────────────────────────────────────

assert "null comment body -> no crash, not pending" \
    '{"comments": [{"login": "haacked", "type": "User", "body": null, "created_at": "2026-08-12T10:00:00Z"}]}' \
    '.pending | length' "0"

# ── Output ordering ──────────────────────────────────────────────────────────
# ReviewHog first, then requested-reviewer entries in input order.

assert "ReviewHog entry sorts before requested-reviewer entries" \
    "$(with_trigger "${T1}" "$(jq -n --argjson u "$(jq -c -n '{login: "greptile-apps[bot]", type: "Bot"}')" '{requested_users: [$u]}')")" \
    '.pending[0].reviewer' "reviewhog"

assert "requested-reviewer entries keep input order" \
    "$(jq -n --argjson ua "$(jq -c -n '{login: "aaa-bot[bot]", type: "Bot"}')" \
        --argjson ub "$(jq -c -n '{login: "zzz-bot[bot]", type: "Bot"}')" \
        '{requested_users: [$ua, $ub]}')" \
    '[.pending[].reviewer]' '["aaa-bot[bot]","zzz-bot[bot]"]'

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
