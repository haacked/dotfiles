#!/bin/bash
# Tests for the GitHub search queries review-all-prs.sh issues in each mode.
#
# Usage: test-review-search-queries.sh
#
# The bug these cover: --pending/--draft used to search involves:@me alone, so
# it missed a fresh draft review on a PR whose only other tie was a review
# request. GitHub does not clear the review request when you start a draft, and
# its search index picks pending reviews up with a lag, so involves: is not a
# superset of review-requested:.
#
# A PATH shim stands in for gh: it answers the member lookups from env vars and
# records every GraphQL searchQuery into a log the assertions read. Every search
# returns an empty page, so the tests assert on which queries ran, not on
# results. Fully offline.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"

BIN="$(cd "$SCRIPT_DIR/.." && pwd)/review-all-prs.sh"

TESTTMP="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TESTTMP"' EXIT

QUERY_LOG="$TESTTMP/queries.log"
mkdir -p "$TESTTMP/bin"

# review-all-prs.sh needs bash 4+ (associative arrays), which macOS's /bin/bash
# is not. Find a modern one and put its directory ahead of the system paths so
# both the interpreter below and any bash the script re-invokes resolve to it.
BASH4=""
for candidate in "$BASH" /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash)"; do
  [[ -x "$candidate" ]] || continue
  # shellcheck disable=SC2016 # BASH_VERSINFO must expand in the candidate, not here
  if [[ "$("$candidate" -c 'echo ${BASH_VERSINFO[0]}')" -ge 4 ]]; then
    BASH4="$candidate"
    break
  fi
done
if [[ -z "$BASH4" ]]; then
  echo "No bash 4+ found; review-all-prs.sh cannot run. Install bash via Homebrew." >&2
  exit 1
fi
SHIM_PATH="$TESTTMP/bin:$(dirname "$BASH4"):/usr/bin:/bin"

# gh shim. Member lookups answer with a fixed two-person team so the --all
# author query has something to build from; graphql calls append their
# searchQuery to $QUERY_LOG and return an empty single page.
cat > "$TESTTMP/bin/gh" <<'SHIM'
#!/bin/bash
if [[ "${1-}" == "api" && "${2-}" == "graphql" ]]; then
  for ((i = 1; i <= $#; i++)); do
    arg="${!i}"
    if [[ "$arg" == searchQuery=* ]]; then
      printf '%s\n' "${arg#searchQuery=}" >> "$QUERY_LOG"
    fi
  done
  echo '{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"edges":[]}}}'
  exit 0
fi
case "${2-}" in
  user) echo "me" ;;
  orgs/*/teams/*/members*)
    # '[.[].login]' asks for a JSON array, '.[].login' for bare lines.
    if [[ "$*" == *"[.[].login]"* ]]; then echo '["dev-one","dev-two"]'
    else printf 'dev-one\ndev-two\n'; fi
    ;;
  orgs/*/members*) echo '["dev-one","dev-two"]' ;;
  *) echo '[]' ;;
esac
SHIM
chmod +x "$TESTTMP/bin/gh"

# Runs review-all-prs.sh with a fresh query log and echoes the log path.
run_queries() {
  : > "$QUERY_LOG"
  run_bounded 20 env PATH="$SHIM_PATH" QUERY_LOG="$QUERY_LOG" "$BASH4" "$BIN" "$@" >/dev/null 2>&1 || true
}

# True when some recorded query contains the given substring.
ran_query() {
  grep -qF -- "$1" "$QUERY_LOG"
}

# ── --draft searches the same candidates as the default mode ────────────────

run_queries --draft
assert "--draft searches review-requested:@me, so a fresh draft on a requested PR is found" \
  ran_query "review-requested:@me"
assert "--draft still sweeps involves:@me for drafts on PRs you weren't asked to review" \
  ran_query "involves:@me"

run_queries --draft --team flags
assert "--draft honors --team via team-review-requested" \
  ran_query "team-review-requested:PostHog/flags"

run_queries --pending
assert "--pending is the same mode as --draft: it searches review-requested:@me too" \
  ran_query "review-requested:@me"

# ── Default and --all modes keep their existing queries ─────────────────────

run_queries
assert "default mode searches review-requested:@me" ran_query "review-requested:@me"
assert "default mode sweeps involves:@me for pending drafts" ran_query "involves:@me"
assert "default mode does not run an author query" \
  test "$(grep -cF -- 'author:dev-one' "$QUERY_LOG")" -eq 0

run_queries --all --priority-team flags
assert "--all searches every open non-draft PR authored by a team member" \
  ran_query "author:dev-one author:dev-two"
assert "--all folds the priority team into team-review-requested" \
  ran_query "team-review-requested:PostHog/flags"
assert "--all sweeps involves:@me for pending drafts" ran_query "involves:@me"

run_queries --org acme --draft
assert "--draft scopes its queries to --org" ran_query "org:acme"

print_results
