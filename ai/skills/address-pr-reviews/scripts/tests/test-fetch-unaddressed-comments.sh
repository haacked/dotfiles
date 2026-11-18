#!/usr/bin/env bash
# Tests for fetch-unaddressed-comments.sh: unresolved inline threads, review bodies,
# and top-level PR comments, minus noise and minus bodies recorded with
# record-dismissed-comment.sh.
#
# A fake gh on PATH answers every call from one fixture file per case, so no test
# reaches the network. It answers the review-thread GraphQL query and the three REST
# endpoints the fetch reads. Any other call fails and is logged, so a new call shape
# shows up as a failure that names the call.
#
# Usage: test-fetch-unaddressed-comments.sh

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "${SCRIPT_DIR}/../../../../../bin/lib/test-helpers.sh"
FETCH="${SCRIPT_DIR}/../fetch-unaddressed-comments.sh"
RECORD="${SCRIPT_DIR}/../record-dismissed-comment.sh"

REPO_SLUG="acme/widgets"
PR="4242"
PR_AUTHOR="pr-owner"

TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "${TEST_ROOT}"' EXIT

mkdir -p "${TEST_ROOT}/bin"

# The fixture (FAKE_GH_WORLD) is one JSON object:
#   pr_author: {login, type}
#   threads:   GraphQL reviewThread nodes
#   reviews:   [{db_id, login, type, state, body, at}]
#   comments:  [{db_id, login, type, body, at}]
# login is the GraphQL login. REST appends "[bot]" to a Bot's login, as GitHub does.
# FAKE_GH_FAIL names one REST source to fail with an HTTP 502: author (the PR
# author), reviews, or comments (top-level comments).
cat > "${TEST_ROOT}/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail

world="${FAKE_GH_WORLD:?FAKE_GH_WORLD is not set}"

unexpected() {
  echo "fake gh: unexpected call: gh $*" >&2
  printf 'UNEXPECTED: %s\n' "$*" >> "${FAKE_GH_LOG:-/dev/null}"
  exit 1
}

fail_if() { # source
  if [[ "${FAKE_GH_FAIL:-}" == "$1" ]]; then
    printf 'FAILED: %s\n' "$1" >> "${FAKE_GH_LOG:-/dev/null}"
    echo "HTTP 502: Bad Gateway" >&2
    exit 1
  fi
}

[[ "${1:-}" == api ]] || unexpected "$@"

if [[ "${2:-}" == graphql ]]; then
  jq -c '{data: {repository: {pullRequest: {reviewThreads: {nodes: .threads,
    pageInfo: {hasNextPage: false, endCursor: null}}}}}}' "$world"
  exit 0
fi

slurp=false
paginate=false
api_path=''
for arg in "${@:2}"; do
  case "$arg" in
    --slurp) slurp=true ;;
    --paginate) paginate=true ;;
    -*) ;;
    *) api_path="${arg%%\?*}" ;;
  esac
done

rest_user='{login: (if .type == "Bot" then .login + "[bot]" else .login end), type}'
base="repos/${FAKE_GH_REPO}"
case "$api_path" in
  "${base}/pulls/${FAKE_GH_PR}")
    fail_if author
    doc=$(jq -c '{user: (.pr_author | '"$rest_user"'), head: {sha: "1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3"}}' "$world")
    ;;
  "${base}/pulls/${FAKE_GH_PR}/reviews")
    fail_if reviews
    doc=$(jq -c --arg repo "$FAKE_GH_REPO" --arg pr "$FAKE_GH_PR" '[.reviews[] | {
        id: .db_id, user: ('"$rest_user"'), body, state, submitted_at: .at,
        html_url: "https://github.com/\($repo)/pull/\($pr)#pullrequestreview-\(.db_id)"
      }]' "$world")
    ;;
  "${base}/issues/${FAKE_GH_PR}/comments")
    fail_if comments
    doc=$(jq -c --arg repo "$FAKE_GH_REPO" --arg pr "$FAKE_GH_PR" '[.comments[] | {
        id: .db_id, user: ('"$rest_user"'), body, created_at: .at,
        html_url: "https://github.com/\($repo)/pull/\($pr)#issuecomment-\(.db_id)"
      }]' "$world")
    ;;
  *) unexpected "$@" ;;
esac

# --slurp wraps each page in an outer array. FAKE_GH_PAGE_SIZE splits a list into
# pages so a fetch that reads only the first page fails.
if [[ "$slurp" == true ]]; then
  [[ "$paginate" == true ]] || unexpected "$@"
  jq -c --argjson n "${FAKE_GH_PAGE_SIZE:-100}" \
    'if length == 0 then [[]] else [range(0; length; $n) as $i | .[$i:$i + $n]] end' <<<"$doc"
else
  printf '%s\n' "$doc"
fi
STUB
chmod +x "${TEST_ROOT}/bin/gh"

CASE_COUNT=0

# assert_out <description> <jq filter> <expected>: compares the filter's compact output
# over the last fetch's stdout. A fetch that did not print JSON fails every assertion.
assert_out() {
  local description="$1" filter="$2" expected="$3" actual
  actual=$(jq -c "$filter" <<<"$out" 2>/dev/null) || actual="invalid JSON: ${out}"
  if [[ "$actual" == "$expected" ]]; then
    passes=$((passes + 1))
  else
    echo "FAIL: ${description}"
    echo "  expected: ${expected}"
    echo "  actual:   ${actual}"
    [[ -n "$err" ]] && echo "  stderr:   ${err}"
    grep '^UNEXPECTED' "${CASE_DIR}/gh.log" 2>/dev/null | sed 's/^/  gh:       /'
    failures=$((failures + 1))
  fi
}

# new_case <world json>: gives the case its own fixture, HOME, and gh call log.
new_case() {
  CASE_COUNT=$((CASE_COUNT + 1))
  CASE_DIR="${TEST_ROOT}/case-${CASE_COUNT}"
  mkdir -p "${CASE_DIR}/home"
  printf '%s\n' "$1" > "${CASE_DIR}/world.json"
}

state_file() {
  echo "${CASE_DIR}/home/.local/state/copilot-review-loop/${REPO_SLUG%%/*}-${REPO_SLUG##*/}-${PR}.json"
}

# run_fetch [VAR=value ...]: runs the fetch script against the current case and sets
# rc, out, and err.
run_fetch() {
  rc=0
  out=$(env HOME="${CASE_DIR}/home" PATH="${TEST_ROOT}/bin:${PATH}" \
    FAKE_GH_WORLD="${CASE_DIR}/world.json" FAKE_GH_LOG="${CASE_DIR}/gh.log" \
    FAKE_GH_REPO="$REPO_SLUG" FAKE_GH_PR="$PR" "$@" \
    "$FETCH" "$REPO_SLUG" "$PR" 2> "${CASE_DIR}/err") || rc=$?
  err=$(<"${CASE_DIR}/err")
}

# record_item <fetch output> <jq selector>: records the body of the one item the
# selector matches the way SKILL.md Step 5 does: jq extracts the body by kind and id
# from the saved fetch output and pipes it to the record script.
record_item() {
  local saved="$1" selector="$2" match
  match=$(jq -c "[.[] | select(${selector})] | if length == 1 then .[0] else error(\"matched \\(length) items\") end" <<<"$saved") || return 1
  jq -r --arg kind "$(jq -r .kind <<<"$match")" --argjson id "$(jq -c .id <<<"$match")" \
    '.[] | select(.kind == $kind and .id == $id) | .body' <<<"$saved" \
    | env HOME="${CASE_DIR}/home" "$RECORD" "$REPO_SLUG" "$PR" > /dev/null
}

# Fixture builders. Each returns one compact JSON value.
thread() { # db_id login type resolved body
  jq -nc --argjson id "$1" --arg login "$2" --arg type "$3" --argjson resolved "$4" --arg body "$5" '{
    isResolved: $resolved, isOutdated: false, path: "src/app.sh", line: 12,
    comments: {nodes: [{databaseId: $id, path: "src/app.sh", line: 12, body: $body,
      diffHunk: "@@ -10,3 +10,3 @@", author: {login: $login, __typename: $type}}]}}'
}
review() { # db_id login type state body
  jq -nc --argjson id "$1" --arg login "$2" --arg type "$3" --arg state "$4" --arg body "$5" '{
    db_id: $id, login: $login, type: $type, state: $state, body: $body,
    at: "2026-11-01T10:00:00Z"}'
}
comment() { # db_id login type body
  jq -nc --argjson id "$1" --arg login "$2" --arg type "$3" --arg body "$4" '{
    db_id: $id, login: $login, type: $type, body: $body,
    at: "2026-11-01T11:00:00Z"}'
}
world() { # threads-json reviews-json comments-json
  jq -nc --arg author "$PR_AUTHOR" --argjson t "$1" --argjson r "$2" --argjson c "$3" \
    '{pr_author: {login: $author, type: "User"}, threads: $t, reviews: $r, comments: $c}'
}
array() { jq -sc '.' <<<"$*"; }

# Bodies the mixed fixture uses, so assertions name them once.
INLINE_BOT="Quote this expansion."
INLINE_RESOLVED="Already fixed."
INLINE_HUMAN="Name the default."
ASK_APPROVED=$'Looks good. Two asks before merge:\n\n1. Rename `fetchAll` to `fetchUnresolved`.\n2. Add a test for the empty case.'
ASK_CHANGES="Please handle the 404 from the lookup."
ASK_COMMENTED="Could you split this function? It does two things."
ASK_DISMISSED="The retry loop never backs off."
PR_COMMENT_ASK="Could you also update the README with the new flag?"
OWNER_REVIEW="Self-review: I still need to clean up the logging."
OWNER_COMMENT="Pushed a fix for the flaky test."
CI_REPORT=$'🤖 CI report\n\nAll 42 checks passed. Coverage 91%.'

mixed_world() {
  world \
    "$(array \
      "$(thread 111 copilot-pull-request-reviewer Bot false "$INLINE_BOT")" \
      "$(thread 222 reviewer-a User true "$INLINE_RESOLVED")" \
      "$(thread 333 reviewer-a User false "$INLINE_HUMAN")")" \
    "$(array \
      "$(review 501 reviewer-a User APPROVED "$ASK_APPROVED")" \
      "$(review 502 reviewer-b User CHANGES_REQUESTED "$ASK_CHANGES")" \
      "$(review 503 reviewer-c User COMMENTED "$ASK_COMMENTED")" \
      "$(review 504 reviewer-f User DISMISSED "$ASK_DISMISSED")" \
      "$(review 505 reviewer-d User APPROVED "")" \
      "$(review 506 reviewer-e User COMMENTED $'  \n\t  ')" \
      "$(review 507 "$PR_AUTHOR" User COMMENTED "$OWNER_REVIEW")")" \
    "$(array \
      "$(comment 601 reviewer-g User "$PR_COMMENT_ASK")" \
      "$(comment 602 "$PR_AUTHOR" User "$OWNER_COMMENT")" \
      "$(comment 603 github-actions Bot "$CI_REPORT")" \
      "$(comment 604 reviewer-h User "")" \
      "$(comment 605 reviewer-h User $'\n  \n')")"
}

# kind_of <body>: jq filter printing the kind of each item with that body.
json_str() { jq -nc --arg s "$1" '$s'; }
kind_of() { printf '[.[] | select(.body == %s) | .kind]' "$(json_str "$1")"; }
# present_and_absent <present body> <absent body>: true when the first body is
# returned and the second is not, so a fetch that returns nothing cannot pass a skip check.
present_and_absent() {
  printf '(any(.[]; .body == %s)) and (all(.[]; .body != %s))' \
    "$(json_str "$1")" "$(json_str "$2")"
}

# The reported bug: the only feedback is an APPROVED review whose body holds asks.
new_case "$(world '[]' "$(array "$(review 501 reviewer-a User APPROVED "$ASK_APPROVED")")" '[]')"
run_fetch
assert "an approved review with asks and no inline threads exits 0" test "$rc" -eq 0
assert_out "an approved review with asks and no inline threads is not an empty result" \
  'length' '1'
assert_out "an approved review body comes back as kind review_body" \
  '[.[] | {kind, author, body, url}]' \
  "$(jq -nc --arg b "$ASK_APPROVED" '[{kind: "review_body", author: "reviewer-a", body: $b, url: "https://github.com/acme/widgets/pull/4242#pullrequestreview-501"}]')"
assert_out "a human review body has is_bot false" '[.[].is_bot]' '[false]'

# A top-level comment is the only feedback.
new_case "$(world '[]' '[]' "$(array "$(comment 601 reviewer-g User "$PR_COMMENT_ASK")")")"
run_fetch
assert_out "a top-level comment from another user comes back as kind pr_comment" \
  '[.[] | {kind, author, body, is_bot, url}]' \
  "$(jq -nc --arg b "$PR_COMMENT_ASK" '[{kind: "pr_comment", author: "reviewer-g", body: $b, is_bot: false, url: "https://github.com/acme/widgets/pull/4242#issuecomment-601"}]')"

# All three kinds together, with noise beside each.
new_case "$(mixed_world)"
run_fetch
assert "the mixed fetch exits 0" test "$rc" -eq 0
mixed_out="$out"

assert_out "unresolved inline comments still come back as kind inline with their fields" \
  '[.[] | select(.kind == "inline") | {id, path, line, diff_hunk, author, is_bot}] | sort_by(.id)' \
  '[{"id":111,"path":"src/app.sh","line":12,"diff_hunk":"@@ -10,3 +10,3 @@","author":"copilot-pull-request-reviewer","is_bot":true},{"id":333,"path":"src/app.sh","line":12,"diff_hunk":"@@ -10,3 +10,3 @@","author":"reviewer-a","is_bot":false}]'
assert_out "a resolved inline thread is not returned" \
  "$(present_and_absent "$INLINE_HUMAN" "$INLINE_RESOLVED")" 'true'

assert_out "an APPROVED review body is returned as review_body" "$(kind_of "$ASK_APPROVED")" '["review_body"]'
assert_out "a CHANGES_REQUESTED review body is returned as review_body" "$(kind_of "$ASK_CHANGES")" '["review_body"]'
assert_out "a COMMENTED review body is returned as review_body" "$(kind_of "$ASK_COMMENTED")" '["review_body"]'
assert_out "a DISMISSED review body is returned, since any state counts" "$(kind_of "$ASK_DISMISSED")" '["review_body"]'
assert_out "a top-level comment from another user is returned as pr_comment" "$(kind_of "$PR_COMMENT_ASK")" '["pr_comment"]'

assert_out "a review with an empty body is skipped" \
  "$(present_and_absent "$ASK_APPROVED" "")" 'true'
assert_out "a review with a whitespace-only body is skipped" \
  '(any(.[]; .kind == "review_body")) and (all(.[]; (.body | test("\\S"))))' 'true'
assert_out "only the four reviews with bodies from other users are returned" \
  '[.[] | select(.kind == "review_body")] | length' '4'
assert_out "the PR author's own review body is skipped" \
  "$(present_and_absent "$ASK_COMMENTED" "$OWNER_REVIEW")" 'true'
assert_out "the PR author's own top-level comment is skipped" \
  "$(present_and_absent "$PR_COMMENT_ASK" "$OWNER_COMMENT")" 'true'
assert_out "a CI report bot comment is skipped" \
  "$(present_and_absent "$PR_COMMENT_ASK" "$CI_REPORT")" 'true'
assert_out "empty and whitespace-only top-level comments are skipped" \
  '[.[] | select(.kind == "pr_comment")] | length' '1'

assert_out "every item has a kind from the three known kinds" \
  'all(.[]; .kind == "inline" or .kind == "review_body" or .kind == "pr_comment")' 'true'
assert_out "every item has a non-empty author string" \
  'all(.[]; (.author | type) == "string" and .author != "")' 'true'
assert_out "every item has a boolean is_bot" 'all(.[]; (.is_bot | type) == "boolean")' 'true'
assert_out "every item has a non-null id" 'all(.[]; .id != null)' 'true'
assert_out "kind and id together are unique across the three kinds" \
  '([.[] | [.kind, .id]] | length) == ([.[] | [.kind, .id]] | unique | length)' 'true'
assert_out "human review bodies and comments have is_bot false" \
  '[.[] | select(.kind != "inline") | .is_bot] | unique' '[false]'

run_fetch FAKE_GH_PAGE_SIZE=2
assert_out "review bodies and comments past the first page come back" \
  '[.[] | select(.kind != "inline") | .id] | sort' '[501,502,503,504,601]'

run_fetch
assert "ids stay the same across two fetches" \
  test "$(jq -c '[.[] | {id, body}] | sort_by(.body)' <<<"$out")" = \
  "$(jq -c '[.[] | {id, body}] | sort_by(.body)' <<<"$mixed_out")"

# Ids of different kinds come from different GitHub tables and can be equal. Each
# item still comes back, and recording one by kind and id leaves the others.
new_case "$(world \
  "$(array "$(thread 900 reviewer-a User false "$INLINE_HUMAN")")" \
  "$(array "$(review 900 reviewer-b User COMMENTED "$ASK_COMMENTED")")" \
  "$(array "$(comment 900 reviewer-g User "$PR_COMMENT_ASK")")")"
run_fetch
collide_out="$out"
assert_out "items of three kinds that share an id all come back" '[.[].kind] | sort' '["inline","pr_comment","review_body"]'
assert "recording the review body that shares an id succeeds" \
  record_item "$collide_out" '.kind == "review_body"'
run_fetch
assert_out "recording one kind with a shared id leaves the other kinds" '[.[].kind] | sort' '["inline","pr_comment"]'

# Rules the fetch script's header states: a bot's review body or top-level comment
# is dropped, and so is an `@posthog review` request.
new_case "$(world '[]' \
  "$(array \
    "$(review 501 reviewer-a User APPROVED "$ASK_APPROVED")" \
    "$(review 508 copilot-pull-request-reviewer Bot COMMENTED "Copilot reviewed 3 out of 3 changed files in this pull request and generated 2 comments.")")" \
  "$(array \
    "$(comment 601 reviewer-g User "$PR_COMMENT_ASK")" \
    "$(comment 606 greptile-apps Bot "Greptile summary: this PR adds a flag.")" \
    "$(comment 607 reviewer-h User "@posthog review --deep")" \
    "$(comment 608 reviewer-h User $'  @PostHog Review')" \
    "$(comment 609 reviewer-h User "@posthog reviewer note: please rename the flag.")" \
    "$(comment 610 reviewer-h User "Please fix the typo. @posthog review")")")"
run_fetch
assert_out "a bot review body is skipped" \
  "$(present_and_absent "$ASK_APPROVED" "Copilot reviewed 3 out of 3 changed files in this pull request and generated 2 comments.")" 'true'
assert_out "a bot top-level comment without a CI report prefix is skipped" \
  "$(present_and_absent "$PR_COMMENT_ASK" "Greptile summary: this PR adds a flag.")" 'true'
assert_out "an @posthog review request is skipped" \
  "$(present_and_absent "$PR_COMMENT_ASK" "@posthog review --deep")" 'true'
assert_out "an @posthog review request with leading space and other case is skipped" \
  "$(present_and_absent "$PR_COMMENT_ASK" $'  @PostHog Review')" 'true'
assert_out "a comment that starts with @posthog reviewer is not a review request" \
  "$(kind_of "@posthog reviewer note: please rename the flag.")" '["pr_comment"]'
assert_out "a comment that ends with @posthog review is not a review request" \
  "$(kind_of "Please fix the typo. @posthog review")" '["pr_comment"]'

# The empty result fires only when no kind has anything left.
new_case "$(world \
  "$(array "$(thread 222 reviewer-a User true "$INLINE_RESOLVED")")" \
  "$(array "$(review 505 reviewer-d User APPROVED "")" "$(review 507 "$PR_AUTHOR" User COMMENTED "$OWNER_REVIEW")")" \
  "$(array "$(comment 602 "$PR_AUTHOR" User "$OWNER_COMMENT")" "$(comment 603 github-actions Bot "$CI_REPORT")")")"
run_fetch
assert "a PR with only noise exits 0" test "$rc" -eq 0
assert_out "a PR with only noise returns an empty array" '.' '[]'

new_case "$(world '[]' '[]' '[]')"
run_fetch
assert "a PR with no feedback at all exits 0" test "$rc" -eq 0
assert_out "a PR with no feedback at all returns an empty array" '.' '[]'

# A failed read of any one source is an error, not an empty result. Each source fails
# on its own, so a fetch that swallows one failure cannot pass on another's.
for source in author reviews comments; do
  new_case "$(world \
    "$(array "$(thread 333 reviewer-a User false "$INLINE_HUMAN")")" \
    "$(array "$(review 501 reviewer-a User APPROVED "$ASK_APPROVED")")" \
    "$(array "$(comment 601 reviewer-g User "$PR_COMMENT_ASK")")")"
  run_fetch FAKE_GH_FAIL="$source"
  assert "the fetch reads ${source} through gh" grep -qx "FAILED: ${source}" "${CASE_DIR}/gh.log"
  assert "a failed read of ${source} exits non-zero" test "$rc" -ne 0
  assert "a failed read of ${source} prints no item list" test -z "$out"
done

# A corrupt state file fails even when the only feedback is a review body.
new_case "$(world '[]' "$(array "$(review 501 reviewer-a User APPROVED "$ASK_APPROVED")")" '[]')"
mkdir -p "$(dirname "$(state_file)")"
echo 'not json' > "$(state_file)"
run_fetch
assert "a corrupt state file fails a fetch that has only review bodies" test "$rc" -ne 0

# Dedupe: an item recorded with record-dismissed-comment.sh stays filtered.
new_case "$(mixed_world)"
run_fetch
first="$out"
assert "recording the approved review body succeeds" \
  record_item "$first" '.kind == "review_body" and (.body | startswith("Looks good."))'
assert "recording the top-level comment succeeds" \
  record_item "$first" '.kind == "pr_comment"'
assert "recording an inline comment succeeds" record_item "$first" '.id == 333'
run_fetch
assert "the fetch after recording exits 0" test "$rc" -eq 0
assert_out "a recorded review body stays filtered on the next fetch" \
  "$(present_and_absent "$ASK_CHANGES" "$ASK_APPROVED")" 'true'
assert_out "a recorded top-level comment stays filtered on the next fetch" \
  "$(present_and_absent "$ASK_CHANGES" "$PR_COMMENT_ASK")" 'true'
assert_out "a recorded inline comment stays filtered on the next fetch" \
  "$(present_and_absent "$INLINE_BOT" "$INLINE_HUMAN")" 'true'
assert_out "recording three items leaves the other items in place" \
  '[.[] | .kind] | sort' '["inline","review_body","review_body","review_body"]'

# Dedupe parity: the record script hashes the body jq extracts from the fetch output,
# and the fetch hashes the body it got from gh. Each body below is stored or escaped
# differently on the way through JSON and the shell, and each must hash the same both ways.
parity_bodies=(
  $'Two asks:\n- quote "$path"\n- escape C:\\temp\\new'
  $'Windows line endings\r\nsecond line\r\n'
  $'  leading and trailing whitespace  \n\n'
  'Unicode: café, naïve, 日本語, 🚀'
  'Contains a literal \n and \t and \"quotes\" in the text'
  '42'
  'null'
  'MiXeD CaSe AsK'
)
for kind in review_body pr_comment; do
  reviews='[]' comments='[]' items=()
  for i in "${!parity_bodies[@]}"; do
    if [[ "$kind" == review_body ]]; then
      items+=("$(review $((700 + i)) "reviewer-$i" User COMMENTED "${parity_bodies[$i]}")")
    else
      items+=("$(comment $((800 + i)) "reviewer-$i" User "${parity_bodies[$i]}")")
    fi
  done
  if [[ "$kind" == review_body ]]; then reviews=$(array "${items[@]}"); else comments=$(array "${items[@]}"); fi
  new_case "$(world '[]' "$reviews" "$comments")"
  run_fetch
  first="$out"
  for i in "${!parity_bodies[@]}"; do
    author="reviewer-$i"
    assert_out "${kind} parity body ${i} is returned before it is recorded" \
      "[.[] | select(.author == \"${author}\") | .kind]" "[\"${kind}\"]"
    assert "${kind} parity body ${i} records" record_item "$first" ".author == \"${author}\""
  done
  run_fetch
  for i in "${!parity_bodies[@]}"; do
    assert_out "${kind} parity body ${i} stays filtered after it is recorded" \
      "[.[] | select(.author == \"reviewer-${i}\")] | length" '0'
  done
done

trigger_pattern() { grep -o 'test("^\\\\s\*@posthog[^"]*")' "$1"; }
fetch_trigger=$(trigger_pattern "$FETCH")
assert "the fetch has an @posthog review pattern" test -n "$fetch_trigger"
assert "the fetch drops the same @posthog review requests as pending-reviews.jq" \
  test "$fetch_trigger" = "$(trigger_pattern "${SCRIPT_DIR}/../helpers/pending-reviews.jq")"

rc=0
"$FETCH" "$REPO_SLUG" > /dev/null 2>&1 || rc=$?
assert "a fetch without a PR number is a usage error" test "$rc" -eq 1

print_results
