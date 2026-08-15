#!/usr/bin/env bash
# Tests for followup-open.sh (open-item selection) and followup-add.sh (insert contract).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OPEN="${SCRIPT_DIR}/../followup-open.sh"
ADD="${SCRIPT_DIR}/../followup-add.sh"

passes=0
failures=0

check() { # desc actual expected
    if [[ "$2" == "$3" ]]; then
        passes=$((passes + 1))
    else
        echo "FAIL: $1"
        echo "  expected [$3], got [$2]"
        failures=$((failures + 1))
    fi
}

fixture() { # writes $FOLLOWUPS_FILE with the given item lines
    { printf '# Followups\n\n## Open\n\n'; printf '%s\n' "$@"; printf '\n## Archive\n'; } > "$FOLLOWUPS_FILE"
}

export FOLLOWUPS_FILE
FOLLOWUPS_FILE=$(mktemp)

# Anchored filter: one repo name must not prefix-match another.
fixture \
    '- [ ] 2026-08-10 · [PostHog/posthog · b1] core' \
    '- [ ] 2026-08-11 · [PostHog/posthog-js · b2] js' \
    '- [ ] 2026-08-12 · [PostHog/posthog] no-branch'
check "posthog filter excludes posthog-js" "$("$OPEN" PostHog/posthog | grep -c .)" "2"
check "posthog-js filter matches only js" "$("$OPEN" PostHog/posthog-js | grep -c .)" "1"

# Position anchor: a context-style bracket in the body must not cross-match.
fixture \
    '- [ ] 2026-08-13 · [haacked/notes · main] mentions [PostHog/posthog] in body' \
    '- [ ] 2026-08-14 · [PostHog/posthog · main] real item'
check "body-text bracket does not cross-match" "$("$OPEN" PostHog/posthog | grep -c .)" "1"

# Closed items are not open.
fixture \
    '- [ ] 2026-08-14 · [PostHog/posthog · b] open one' \
    '- [x] 2026-08-01 · [PostHog/posthog · b] done — closed 2026-08-02'
check "closed item excluded from open" "$("$OPEN" | grep -c .)" "1"

# Insert contract: fresh skeleton, newest-first, blank lines intact.
FOLLOWUPS_FILE=$(mktemp) && rm -f "$FOLLOWUPS_FILE"
"$ADD" "first" > /dev/null
"$ADD" "second" > /dev/null
check "two items present" "$(grep -c '^- \[ \]' "$FOLLOWUPS_FILE")" "2"
check "newest first" "$(grep '^- \[ \]' "$FOLLOWUPS_FILE" | head -1 | grep -c second)" "1"
check "blank line kept after ## Open" "$(grep -A1 '^## Open$' "$FOLLOWUPS_FILE" | sed -n '2p')" ""
check "blank line kept before ## Archive" "$(grep -B1 '^## Archive$' "$FOLLOWUPS_FILE" | sed -n '1p')" ""

# Item text containing '## Open' must not create a second insert point.
FOLLOWUPS_FILE=$(mktemp) && rm -f "$FOLLOWUPS_FILE"
"$ADD" 'reword the ## Open heading' > /dev/null
"$ADD" 'x' > /dev/null
check "no double insert on heading-like text" "$(grep -c '^- \[ \]' "$FOLLOWUPS_FILE")" "2"

# Escaping: backslashes, ampersands, and slashes survive the awk insert.
FOLLOWUPS_FILE=$(mktemp) && rm -f "$FOLLOWUPS_FILE"
"$ADD" 'tricky \back & amp /sl/ash' > /dev/null
check "escaping survives" "$(grep -cF 'tricky \back & amp /sl/ash' "$FOLLOWUPS_FILE")" "1"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
