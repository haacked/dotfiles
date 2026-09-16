#!/usr/bin/env bash
# Tests for derive_org_repo across origin URL shapes, and for resolve_branch_name
# across its tiers.
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

# ── resolve_branch_name ─────────────────────────────────────────────────────

SHIM_DIR=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR"' EXIT
cat > "${SHIM_DIR}/gh" <<'SHIM'
#!/usr/bin/env bash
# SELF stands in for the sha the caller asked about, so a fixture can say "this
# PR's head is the commit under test" without the test knowing the sha.
[ "$1" = api ] || exit 1
printf '%s' "${GH_API_JSON-[]}" | sed "s/SELF/${GIT_PR_HEAD_SHA}/g" | jq -r "${4-.}"
SHIM
chmod +x "${SHIM_DIR}/gh"

# Prints resolve_branch_name's answer, or "none", from a throwaway repo. Pass
# "detach" as the first argument to run it with no branch checked out; the rest
# become resolve_branch_name's own arguments.
try_branch() { # [detach] [network]
    local d detach=""
    [[ "${1-}" == detach ]] && { detach=yes; shift; }
    d=$(mktemp -d)
    git -C "$d" init -q -b haacked/work
    # A CI runner has no global git identity, and an unborn HEAD makes the
    # detach below read "HEAD" as a path instead.
    git -C "$d" -c user.email=test@example.com -c user.name=Test \
        -c commit.gpgsign=false commit -q --allow-empty -m first
    [[ -n "$detach" ]] && git -C "$d" checkout -q --detach
    (cd "$d" && PATH="${SHIM_DIR}:${PATH}" \
        bash -c 'source "$1"; shift; resolve_branch_name "$@" || echo none' _ "${SCRIPT_DIR}/../repo-context.sh" "$@")
    rm -rf "$d"
}

check "attached checkout" "$(try_branch)" "haacked/work"
check "RAN_BRANCH does not override a real branch" "$(RAN_BRANCH=other try_branch)" "haacked/work"
check "detached with no tier left" "$(try_branch detach)" "none"
check "detached falls back to RAN_BRANCH" "$(RAN_BRANCH=haacked/env try_branch detach)" "haacked/env"
check "detached without the network argument never asks GitHub" \
    "$(GH_API_JSON='[{"head":{"sha":"x","ref":"haacked/pr"},"state":"open"}]' try_branch detach)" "none"

MATCHING='[{"head":{"sha":"SELF","ref":"haacked/pr"},"state":"open"}]'
check "detached resolves the head ref of the PR whose head is this commit" \
    "$(GH_API_JSON="$MATCHING" try_branch detach network)" "haacked/pr"
check "detached rejects a PR this commit only merged into" \
    "$(GH_API_JSON='[{"head":{"sha":"deadbeef","ref":"haacked/merged-into"},"state":"open"}]' try_branch detach network)" "none"
check "detached prefers the open PR" \
    "$(GH_API_JSON='[{"head":{"sha":"SELF","ref":"a"},"state":"closed"},{"head":{"sha":"SELF","ref":"b"},"state":"open"}]' try_branch detach network)" "b"
check "detached with no associated PR" "$(GH_API_JSON='[]' try_branch detach network)" "none"

# ── resolve_branch_name cache tier ──────────────────────────────────────────
# A branch resolved via RAN_BRANCH or the network tier persists to a file
# under the checkout's private git dir. A later call in the same checkout, run
# as a separate process, reads that file instead of RAN_BRANCH or the network.
# This is what lets `/ran` read a detached checkout's branch after a commit
# has moved HEAD off the PR head it was resolved from.

CACHE_REPO=$(mktemp -d)
NETWORK_REPO=$(mktemp -d)
trap 'rm -rf "$SHIM_DIR" "$CACHE_REPO" "$NETWORK_REPO"' EXIT

git -C "$CACHE_REPO" init -q -b haacked/work
git -C "$CACHE_REPO" -c user.email=test@example.com -c user.name=Test \
    -c commit.gpgsign=false commit -q --allow-empty -m first
git -C "$CACHE_REPO" checkout -q --detach

resolve_in_cache_repo() { # [args...] -> prints resolve_branch_name's answer or "none"
    (cd "$CACHE_REPO" && PATH="${SHIM_DIR}:${PATH}" \
        bash -c 'source "$1"; shift; resolve_branch_name "$@" || echo none' _ "${SCRIPT_DIR}/../repo-context.sh" "$@")
}

RAN_BRANCH=haacked/cached resolve_in_cache_repo > /dev/null
check "a RAN_BRANCH-resolved branch persists for a later call with no RAN_BRANCH" \
    "$(resolve_in_cache_repo)" "haacked/cached"
check "the cache tier never asks GitHub" \
    "$(GH_API_JSON='[{"head":{"sha":"x","ref":"haacked/other"},"state":"open"}]' resolve_in_cache_repo network)" "haacked/cached"

git -C "$NETWORK_REPO" init -q -b haacked/work
git -C "$NETWORK_REPO" -c user.email=test@example.com -c user.name=Test \
    -c commit.gpgsign=false commit -q --allow-empty -m first
git -C "$NETWORK_REPO" checkout -q --detach
NETWORK_SHA=$(git -C "$NETWORK_REPO" rev-parse HEAD)

resolve_in_network_repo() { # [args...] -> prints resolve_branch_name's answer or "none"
    (cd "$NETWORK_REPO" && PATH="${SHIM_DIR}:${PATH}" \
        bash -c 'source "$1"; shift; resolve_branch_name "$@" || echo none' _ "${SCRIPT_DIR}/../repo-context.sh" "$@")
}

MATCH_NETWORK=$(printf '[{"head":{"sha":"%s","ref":"haacked/from-network"},"state":"open"}]' "$NETWORK_SHA")
GH_API_JSON="$MATCH_NETWORK" resolve_in_network_repo network > /dev/null
check "a network-resolved branch persists for a later call with no network argument" \
    "$(resolve_in_network_repo)" "haacked/from-network"
check "the cache tier wins over a subsequent network miss, as a commit moving HEAD off the PR head causes" \
    "$(GH_API_JSON='[]' resolve_in_network_repo network)" "haacked/from-network"

echo ""
echo "Passed: ${passes}, Failed: ${failures}"
[[ "${failures}" -eq 0 ]]
