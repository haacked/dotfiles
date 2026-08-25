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
# is not, so find a modern one to run it with. Its directory also goes on the
# shim PATH ahead of the system paths, which covers Homebrew-installed tools the
# script needs (jq) on hosts where /usr/bin carries no copy.
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
  query=""
  for ((i = 1; i <= $#; i++)); do
    arg="${!i}"
    if [[ "$arg" == searchQuery=* ]]; then
      query="${arg#searchQuery=}"
      printf '%s\n' "$query" >> "$QUERY_LOG"
    fi
  done
  # PR_FIXTURE_QUERY names a substring; searches matching it return a page of
  # two PRs, every other search an empty page. That reproduces a draft only some
  # qualifiers can see. 99001 carries an unsubmitted draft review by "me";
  # 99002 carries no review at all, so it is what pending mode has to drop.
  if [[ -n "${PR_FIXTURE_QUERY-}" && "$query" == *"$PR_FIXTURE_QUERY"* ]]; then
    cat <<'NODE'
{"data":{"search":{"pageInfo":{"hasNextPage":false,"endCursor":null},"edges":[{"node":{
"number":99001,
"title":"feat(flags): fixture PR carrying a fresh draft review",
"url":"https://github.com/PostHog/posthog/pull/99001",
"repository":{"nameWithOwner":"PostHog/posthog"},
"author":{"login":"dev-one"},
"updatedAt":"2026-08-24T12:00:00Z",
"reviews":{"nodes":[{"author":{"login":"me"},"state":"PENDING","submittedAt":null}]},
"commits":{"nodes":[{"commit":{"committedDate":"2026-08-24T11:00:00Z"}}]}
}},{"node":{
"number":99002,
"title":"feat(flags): fixture PR you have not reviewed",
"url":"https://github.com/PostHog/posthog/pull/99002",
"repository":{"nameWithOwner":"PostHog/posthog"},
"author":{"login":"dev-two"},
"updatedAt":"2026-08-24T12:00:00Z",
"reviews":{"nodes":[]},
"commits":{"nodes":[{"commit":{"committedDate":"2026-08-24T11:00:00Z"}}]}
}}]}}}
NODE
    exit 0
  fi
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

RUN_DEADLINE=20

# Truncates the query log, then runs review-all-prs.sh with the given flags and
# echoes its stdout. $1 arms the fixture PR for searches whose query contains
# it; pass "" for none. A non-zero exit means the script stopped before it
# recorded any queries, and every assertion below would then blame the query set
# rather than the environment, so say what actually happened. run_bounded
# discards the command's stderr itself, so no redirect belongs on this call.
run_script() {  # run_script <fixture-query|""> [flags...]
  local fixture="$1" rc=0
  shift
  : > "$QUERY_LOG"
  run_bounded "$RUN_DEADLINE" env PATH="$SHIM_PATH" QUERY_LOG="$QUERY_LOG" \
    PR_FIXTURE_QUERY="$fixture" "$BASH4" "$BIN" "$@" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    local why=""
    [[ "$rc" -eq 124 ]] && why=" (killed after ${RUN_DEADLINE}s)"
    echo "SETUP: review-all-prs.sh $* exited ${rc}${why}" >&2
  fi
}

# Runs review-all-prs.sh for its queries alone, discarding its output.
run_queries() {
  run_script "" "$@" >/dev/null
}

# Runs review-all-prs.sh with the fixture PR armed for searches whose query
# contains $1, and echoes its stdout.
run_with_fixture() {  # run_with_fixture <query-substring> [flags...]
  run_script "$@"
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
assert_not "--draft's sweep keeps your own PRs, where a draft is still unfinished work" \
  ran_query "involves:@me -author:@me"

run_queries --draft --team flags
assert "--draft honors --team via team-review-requested" \
  ran_query "team-review-requested:PostHog/flags"

# Guards the shared --pending|--draft case arm rather than the query set.
run_queries --pending
assert "--pending is an alias for --draft and searches the same candidates" \
  ran_query "review-requested:@me"

# ── Default and --all modes keep their existing queries ─────────────────────

run_queries
assert "default mode searches review-requested:@me" ran_query "review-requested:@me"
assert "default mode sweeps involves:@me for pending drafts" ran_query "involves:@me"
assert "default mode's sweep excludes your own PRs" ran_query "involves:@me -author:@me"
assert_not "default mode does not run an author query" ran_query "author:dev-one"

run_queries --all --priority-team flags
assert "--all searches every open non-draft PR authored by a team member" \
  ran_query "author:dev-one author:dev-two"
assert "--all folds the priority team into team-review-requested" \
  ran_query "team-review-requested:PostHog/flags"
assert "--all sweeps involves:@me for pending drafts" ran_query "involves:@me"

run_queries --org acme --draft
assert "--draft scopes its queries to --org" ran_query "org:acme"

# ── The bug end to end: a draft only review-requested: can see ──────────────
# The fixture answers review-requested:@me and leaves involves:@me empty, which
# is the index lag observed on a freshly started draft review. Searching
# involves:@me alone, as --draft used to, reports nothing here.

out=$(run_with_fixture "review-requested:@me" --draft --json)
assert "--draft reports a draft found only through review-requested:@me" \
  grep -q '"number": 99001' <<< "$out"
assert "--draft reports that PR as an unsubmitted draft" \
  grep -q '"user_review_state": "PENDING"' <<< "$out"
assert_not "--draft leaves out a review-requested PR you have no draft on" \
  grep -q '"number": 99002' <<< "$out"

out=$(run_with_fixture "involves:@me" --draft --json)
assert "--draft still reports a draft found only through the involves sweep" \
  grep -q '"number": 99001' <<< "$out"

# The hidden count measures the new-commits gate, which pending mode's extra
# PENDING filter makes meaningless, so pending mode must not report one.
out=$(run_with_fixture "review-requested:@me" --draft)
assert_not "--draft does not count non-draft PRs as hidden by the new-commits gate" \
  grep -q "no new commits since" <<< "$out"

print_results
