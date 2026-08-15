#!/usr/bin/env bash
# Tests for notes-path.sh, the single owner of the org/repo → vault-path mapping.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NP="${SCRIPT_DIR}/../notes-path.sh"

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

check "posthog notes" "$("$NP" PostHog/posthog)" "$HOME/dev/haacked/notes/PostHog/repositories/posthog"
check "posthog org is case-insensitive" "$("$NP" posthog/posthog-js)" "$HOME/dev/haacked/notes/PostHog/repositories/posthog-js"
check "dev notes" "$("$NP" haacked/dotfiles)" "$HOME/dev/haacked/notes/Dev/repositories/haacked/dotfiles"
check "dev plans" "$("$NP" haacked/dotfiles plans)" "$HOME/dev/haacked/notes/Dev/repositories/haacked/dotfiles/plans"
check "posthog plans" "$("$NP" PostHog/posthog plans)" "$HOME/dev/haacked/notes/PostHog/repositories/posthog/plans"
check "bad kind rejected" "$("$NP" a/b nope 2>&1 | grep -c 'Error' || true)" "1"
check "missing slash rejected" "$("$NP" nope 2>&1 | grep -c 'Usage' || true)" "1"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
