#!/usr/bin/env bash
# Tests for standup-save.sh.
#
# Usage: test-standup-save.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SAVE="${SCRIPT_DIR}/../standup-save.sh"
FIND="${SCRIPT_DIR}/../standup-find.sh"

TESTTMP="$(mktemp -d)"
trap 'rm -rf "${TESTTMP}"' EXIT

export HOME="${TESTTMP}/home"
unset XDG_CACHE_HOME
state_dir="${HOME}/.cache/standup"
notes_dir="${TESTTMP}/notes"
archive_dir="${HOME}/dev/haacked/notes/PostHog/raw/standup"

passes=0
failures=0

assert() {
    local description="$1"
    shift
    if "$@"; then
        passes=$((passes + 1))
    else
        echo "FAIL: ${description}"
        failures=$((failures + 1))
    fi
}

reset_state() {
    rm -rf "${HOME}" "${notes_dir}"
    mkdir -p "${state_dir}" "${notes_dir}" "${archive_dir}"
    printf 'Working on:\n' > "${archive_dir}/2026-11-02.md"
    touch -t 202611021600.00 "${archive_dir}/2026-11-02.md"
}

gathered_at="2026-11-04T16:00:00Z"

# write_gather <url>... -> writes gather.json with those URLs as must_list, the
# current standup-find.sh row as its basis, and gathered_at as its start time.
write_gather() {
    jq -n --arg basis "$("${FIND}")" --arg gathered_at "${gathered_at}" \
        '{basis: $basis, gathered_at: $gathered_at, must_list: $ARGS.positional}' \
        --args "$@" > "${state_dir}/gather.json"
}

# save <path> <notes> -> runs the script with the notes on stdin. It sets rc
# and err.
save() {
    rc=0
    printf '%s' "$2" | "${SAVE}" "$1" 2> "${TESTTMP}/err" > /dev/null || rc=$?
    err="$(cat "${TESTTMP}/err")"
}

mtime() {
    if [[ "${OSTYPE}" == darwin* ]]; then
        stat -f %m "$1"
    else
        stat -c %Y "$1"
    fi
}

# posted_at <file> -> the file's mtime in the UTC ISO 8601 form gather.json uses.
posted_at() {
    if [[ "${OSTYPE}" == darwin* ]]; then
        date -u -r "$(mtime "$1")" +%Y-%m-%dT%H:%M:%SZ
    else
        date -u -d "@$(mtime "$1")" +%Y-%m-%dT%H:%M:%SZ
    fi
}

date="2026-11-04"
path="${notes_dir}/${date}.md"
pr12="https://github.com/PostHog/posthog/pull/12"
pr123="https://github.com/PostHog/posthog/pull/123"
pr7="https://github.com/PostHog/posthog-js/pull/7"
notes="Yesterday:
- Fixed a thing (${pr12} - merged)
- Shipped js (${pr7} - merged)

Working on:
- Nothing new
"

reset_state
write_gather "${pr12}" "${pr7}"
save "${path}" "${notes}"
assert "notes that list every must_list PR save" test "${rc}" -eq 0
assert "a save writes stdin to the path" test "$(cat "${path}")" = "$(printf '%s' "${notes}")"
assert "a save sets the file's mtime to the gather's start time" \
    test "$(posted_at "${path}")" = "${gathered_at}"

reset_state
gathered_at="" write_gather "${pr12}" "${pr7}"
save "${path}" "${notes}"
assert "a gather.json with no gathered_at refuses the save" test "${rc}" -eq 1
assert "a gather.json with no gathered_at leaves the path uncreated" test ! -e "${path}"

reset_state
write_gather
save "${path}" "No PRs today."
assert "an empty must_list saves any notes" test "${rc}" -eq 0

reset_state
write_gather "${pr12}"
echo "old notes" > "${path}"
save "${path}" "${notes}"
assert "a passing save replaces an existing file" test "$(cat "${path}")" = "$(printf '%s' "${notes}")"

reset_state
save "${path}" "${notes}"
assert "a missing gather.json refuses the save" test "${rc}" -eq 1
assert "a missing gather.json says why" test -n "${err}"
assert "a missing gather.json leaves the path uncreated" test ! -e "${path}"

# A newer notes file moves the next cutoff past PRs this gather never saw.
reset_state
write_gather "${pr12}"
printf 'Working on:\n' > "${archive_dir}/2026-11-03.md"
save "${path}" "${notes}"
assert "a gather from before the newest notes file refuses the save" test "${rc}" -eq 1
assert "a stale gather says why" grep -qF "changed after standup-gather.sh ran" <<<"${err}"
assert "a stale gather leaves the path uncreated" test ! -e "${path}"

reset_state
write_gather "${pr12}"
touch "${archive_dir}/2026-11-02.md"
save "${path}" "${notes}"
assert "a gather from before the newest notes file was modified refuses the save" test "${rc}" -eq 1

reset_state
write_gather "${pr12}" "${pr7}"
save "${path}" "Yesterday:
- Fixed a thing (${pr12} - merged)
"
assert "notes missing a must_list PR refuse the save" test "${rc}" -eq 1
assert "notes missing a must_list PR name it on stderr" grep -qF "${pr7}" <<<"${err}"
assert "notes missing a must_list PR do not name the listed one" bash -c '! grep -qxF "$1" <<<"$2"' _ "${pr12}" "${err}"
assert "notes missing a must_list PR leave the path uncreated" test ! -e "${path}"
save "${path}" "${notes}"
assert "a save that adds the missing PRs after a refusal succeeds" test "${rc}" -eq 0

reset_state
write_gather "${pr12}"
save "${path}" "Yesterday:
- Something else (${pr123} - merged)
"
assert "a URL that only prefixes a listed URL does not count" test "${rc}" -eq 1
assert "a URL that only prefixes a listed URL is named as missing" grep -qF "${pr12}" <<<"${err}"
assert "a URL that only prefixes a listed URL leaves the path uncreated" test ! -e "${path}"

reset_state
write_gather "${pr12}"
save "${path}" "Yesterday:
- In another repo (https://github.com/PostHog/posthog-js/pull/12 - merged)
"
assert "the same PR number in another repo does not count" test "${rc}" -eq 1

reset_state
write_gather "${pr12}"
save "${path}" "Yesterday:
- Fixed a thing (${pr12}3 - merged), and ${pr12}
"
assert "a listed URL that also appears as a prefix still counts" test "${rc}" -eq 0

reset_state
write_gather "${pr12}" "${pr7}"
printf 'previous notes\n' > "${path}"
touch -t 202601010000.00 "${path}"
before_mtime="$(mtime "${path}")"
save "${path}" "Yesterday:
- Fixed a thing (${pr12} - merged)
"
assert "a refused save over an existing file fails" test "${rc}" -eq 1
assert "a refused save keeps the existing content" test "$(cat "${path}")" = "previous notes"
assert "a refused save keeps the existing mtime" test "$(mtime "${path}")" = "${before_mtime}"

reset_state
printf 'previous notes\n' > "${path}"
touch -t 202601010000.00 "${path}"
before_mtime="$(mtime "${path}")"
save "${path}" "${notes}"
assert "a save without a gather keeps the existing content" test "$(cat "${path}")" = "previous notes"
assert "a save without a gather keeps the existing mtime" test "$(mtime "${path}")" = "${before_mtime}"

reset_state
rc=0
"${SAVE}" < /dev/null > /dev/null 2>&1 || rc=$?
assert "a save with no path is a usage error" test "${rc}" -eq 64

# XDG_CACHE_HOME moves the state dir.

reset_state
write_gather "${pr12}"
rc=0
printf '%s' "${notes}" | XDG_CACHE_HOME="${TESTTMP}/xdg" "${SAVE}" "${path}" > /dev/null 2>&1 || rc=$?
assert "a save ignores the default gather.json when XDG_CACHE_HOME is set" test "${rc}" -eq 1

mkdir -p "${TESTTMP}/xdg/standup"
mv "${state_dir}/gather.json" "${TESTTMP}/xdg/standup/gather.json"
rc=0
printf '%s' "${notes}" | XDG_CACHE_HOME="${TESTTMP}/xdg" "${SAVE}" "${path}" > /dev/null 2>&1 || rc=$?
assert "a save reads gather.json from XDG_CACHE_HOME when it is set" test "${rc}" -eq 0

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
