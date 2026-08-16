#!/usr/bin/env bash
# Tests for derive_org_repo across origin URL shapes.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../repo-context.sh"

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

try_url() { # url -> prints "org/repo" or "none"
    local d
    d=$(mktemp -d)
    trap 'rm -rf "$d"' RETURN
    git -C "$d" init -q
    git -C "$d" remote add origin "$1"
    (cd "$d" && if derive_org_repo; then printf '%s/%s\n' "$REPO_ORG" "$REPO_REPO"; else echo none; fi)
}

check "ssh url" "$(try_url 'git@github.com:PostHog/posthog.git')" "PostHog/posthog"
check "https with .git" "$(try_url 'https://github.com/haacked/dotfiles.git')" "haacked/dotfiles"
check "https bare" "$(try_url 'https://github.com/haacked/dotfiles')" "haacked/dotfiles"
check "ssh host alias" "$(try_url 'git@github.com-work:PostHog/posthog.git')" "PostHog/posthog"
check "dotted repo name" "$(try_url 'git@github.com:PostHog/posthog.com.git')" "PostHog/posthog.com"
check "non-github origin" "$(try_url 'git@gitlab.com:org/repo.git')" "none"
check "github-prefixed host rejected" "$(try_url 'git@github.company.com:org/repo.git')" "none"
check "github-suffixed host rejected" "$(try_url 'https://mygithub.com/org/repo')" "none"
check "github subdomain rejected" "$(try_url 'https://foo.github.com/org/repo')" "none"
check "ssh:// url accepted" "$(try_url 'ssh://git@github.com/PostHog/posthog.git')" "PostHog/posthog"
check "outside a repo" "$( (cd "$(mktemp -d)" && if derive_org_repo; then echo yes; else echo none; fi) )" "none"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
