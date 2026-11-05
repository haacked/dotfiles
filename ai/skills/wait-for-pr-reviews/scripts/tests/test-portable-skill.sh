#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../helpers/portable-skill-sandbox.sh"

sandbox=$(make_portable_sandbox "$SCRIPT_DIR/../..")
trap 'rm -rf "$sandbox"' EXIT

cat >"$sandbox/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'branch --show-current') echo local-review ;;
  'config branch.local-review.merge') echo refs/heads/contributor-feature ;;
  'config branch.local-review.pushRemote') echo contributor ;;
  'symbolic-ref --quiet --short refs/remotes/contributor/HEAD') echo contributor/main ;;
  'remote get-url contributor') echo git@github.com:Contributor/posthog.git ;;
  'rev-parse --short HEAD') echo abc1234 ;;
  *) echo "Unexpected git arguments: $*" >&2; exit 1 ;;
esac
MOCK

cat >"$sandbox/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$MOCK_CALLS"
projection='.'
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == '--jq' || "${!i}" == '-q' ]]; then
    next=$((i + 1))
    projection="${!next}"
  fi
done

if [[ "$1 $2" == 'repo view' ]]; then
  echo '{"nameWithOwner":"PostHog/posthog"}' | jq -r "$projection"
elif [[ "$1 $2" == 'pr list' ]]; then
  [[ "$*" == *'--head contributor-feature'* && "${GIT_PR_OWNER:-}" == contributor ]]
  echo '[{"url":"https://github.com/PostHog/posthog/pull/1","state":"OPEN","headRepositoryOwner":{"login":"unrelated"}},{"url":"https://github.com/PostHog/posthog/pull/98865","state":"OPEN","headRepositoryOwner":{"login":"Contributor"}}]' | jq -r "$projection"
elif [[ "$1 $2" == 'api graphql' && "$*" == *resolveReviewThread* ]]; then
  [[ "$MOCK_STATE" != resolve_failure ]] || exit 1
elif [[ "$1 $2" == 'api graphql' && "$*" == *reviewThreads* ]]; then
  [[ "$*" == *'owner=PostHog'* && "$*" == *'repo=posthog'* && "$*" == *'number=98865'* ]]
  [[ "$MOCK_STATE" != threads_failure ]] || exit 1
  # Comment 444 is Copilot with a User type, so only its login marks it as a bot.
  # Comment 777 is a bot's, but its thread is already resolved.
  jq -n '{data: {repository: {pullRequest: {reviewThreads: {
    nodes: [[111, "greptile-apps[bot]", "Bot"], [333, "human", "User"], [444, "Copilot", "User"],
      [555, "greptile-apps[bot]", "Bot"], [777, "greptile-apps[bot]", "Bot"]
      | {id: "PRRT_\(.[0])", isResolved: (.[0] == 777), isOutdated: false, path: "bin/deploy.sh", line: 12,
        comments: {nodes: [{databaseId: .[0], path: "bin/deploy.sh", line: 12, body: "Review comment.",
          diffHunk: "@@ -10,3 +10,3 @@", author: {login: .[1], __typename: .[2]}}]}}],
    pageInfo: {hasNextPage: false, endCursor: null}}}}}}' | jq -r "$projection"
elif [[ "$1 $2" == 'api graphql' ]]; then
  [[ "$*" == *'owner=PostHog'* && "$*" == *'name=posthog'* && "$*" == *'pr=98865'* ]]
  if [[ "$MOCK_STATE" == clear ]]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"reviewers"}},{"requestedReviewer":{"__typename":"User","login":"human"}}]}}}}}' | jq -r "$projection"
  else
    echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Bot","login":"greptile-apps[bot]"}},{"requestedReviewer":{"__typename":"User","login":"copilot-pull-request-reviewer[bot]"}},{"requestedReviewer":{"__typename":"User","login":"human"}},{"requestedReviewer":{"__typename":"Team","name":"reviewers"}},{"requestedReviewer":{"__typename":"Mannequin","login":"former-user"}},{"requestedReviewer":null}]}}}}}' | jq -r "$projection"
  fi
elif [[ "$1" == api && "$*" == *'repos/PostHog/posthog/'* ]]; then
  case "$*" in
    *'/timeline?per_page=100'*) echo '[[]]' ;;
    *'/reviews?per_page=100'*)
      if [[ "$MOCK_STATE" == reviewed_head ]]; then
        echo '[[{"user":{"login":"posthog[bot]","type":"Bot"},"body":"<!-- reviewhog:published:1:1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3:full -->","commit_id":"1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3","submitted_at":"2026-09-15T09:00:00Z"}]]'
      else
        echo '[[]]'
      fi
      ;;
    *'/comments?per_page=100'*)
      if [[ "$MOCK_STATE" == clear ]]; then
        echo '[[]]'
      else
        echo '[[{"user":{"login":"human","type":"User"},"body":"@posthog review --deep","created_at":"2026-09-15T10:00:00Z","updated_at":"2026-09-15T10:00:00Z"}]]'
      fi
      ;;
    *'/pulls/98865/comments/'*'/replies '*)
      for arg in "$@"; do
        [[ "$arg" != body=* ]] || printf '%s\n' "$arg" >> "$MOCK_CALLS"
      done
      [[ "$*" != *'/comments/555/'* ]]
      ;;
    *'/pulls/98865')
      [[ "$MOCK_STATE" != failure ]] || exit 1
      echo '{"head":{"sha":"1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3"}}'
      ;;
    *) echo "Unexpected API arguments: $*" >&2; exit 1 ;;
  esac
else
  echo "Unexpected gh arguments: $*" >&2
  exit 1
fi
MOCK
chmod +x "$sandbox/bin/git" "$sandbox/bin/gh"

# The mock records each gh call so a retry count can be asserted, and MOCK_STATE picks
# which verdict it returns. ASSERT_ENV has to be declared local here: written as a
# command prefix on assert_run the array would become the literal text of a scalar.
assert_run_state() { # description mock_state expected_status jq_filter expected cmd...
  local description="$1" mock_state="$2"
  shift 2
  : >"$sandbox/calls"
  # shellcheck disable=SC2034 # assert_run reads this through bash's dynamic scoping.
  local -a ASSERT_ENV=(MOCK_STATE="$mock_state" MOCK_CALLS="$sandbox/calls")
  assert_run "$description" "$@"
}

cd "$sandbox/unrelated"
scripts="$sandbox/skill/scripts"
target=$'PostHog\tposthog\tPostHog/posthog\t98865'

assert_run_state 'detect a PR URL from the copied skill' pending 0 '' "$target" \
  "$scripts/detect-pr.sh" https://github.com/PostHog/posthog/pull/98865
assert_run_state 'detect a PR number from the copied skill' pending 0 '' "$target" \
  "$scripts/detect-pr.sh" 98865
assert_run_state 'detect the renamed local branch in the correct fork' pending 0 '' "$target" \
  "$scripts/detect-pr.sh"

# shellcheck disable=SC2016
assert_run_state 'project GraphQL User and Bot reviewers and exclude teams' pending 0 '.' \
  '[{"login":"greptile-apps[bot]","type":"Bot"},{"login":"copilot-pull-request-reviewer[bot]","type":"User"},{"login":"human","type":"User"}]' \
  bash -c 'source "$1/lib/github.sh"; get_requested_reviewers PostHog/posthog 98865' bash "$scripts"

pending_filter='{pending: (.pending | sort_by(.reviewer)), warnings}'
pending_verdict='{"pending":[{"reviewer":"copilot-pull-request-reviewer[bot]","signal":"requested_reviewer","since":null},{"reviewer":"greptile-apps[bot]","signal":"requested_reviewer","since":null},{"reviewer":"reviewhog","signal":"comment","since":"2026-09-15T10:00:00Z"}],"warnings":[]}'
assert_run_state 'compute pending reviews using the bundled libraries' pending 0 "$pending_filter" "$pending_verdict" \
  "$scripts/check-pending-reviews.sh" PostHog/posthog 98865
assert_run_state 'count a published review of the head from before the trigger' reviewed_head 0 \
  '[.pending[].reviewer] | index("reviewhog")' 'null' \
  "$scripts/check-pending-reviews.sh" PostHog/posthog 98865
assert_run_state 'exit immediately when reviews have cleared' clear 0 '.' '{"pending":[],"warnings":[]}' \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --timeout 0
assert_run_state 'preserve the pending verdict on timeout' pending 2 "$pending_filter" "$pending_verdict" \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --timeout 0
assert_run_state 'fail after repeated fetch failures' failure 1 '' '' \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --timeout 30

assert_line_count 'retry failed fetches exactly three times' "$sandbox/calls" 3

# A fresh heartbeat makes the bundled gh-events report a running daemon. With no
# event arriving, the script waits out --recheck on the queue between checks. With
# --interval 0 and no daemon, it would check dozens of times in the same two seconds.
events_dir="$sandbox/home/.local/state/gh-events"
mkdir -p "$events_dir"
: >"$events_dir/heartbeat"
assert_run_state 'wait on the gh-events queue when the daemon runs' pending 2 '.pending | length' 3 \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --recheck 1 --timeout 2
checks=$(grep -c 'pulls/98865$' "$sandbox/calls" || true)
if [ "$checks" -ge 2 ] && [ "$checks" -le 3 ] && ! grep -q 'daemon is not running' "$ASSERT_STDERR"; then
  passes=$((passes + 1))
else
  echo "FAIL: check once per --recheck while the daemon runs (got $checks checks)"
  cat "$ASSERT_STDERR"
  failures=$((failures + 1))
fi
assert_run 'register a review watch for the PR' 0 '[.reviews, .ci]' '[true,false]' \
  cat "$events_dir/watches/posthog__posthog__98865.json"
rm -rf "$events_dir"

# The wrapper prints each reply the mock received and each thread it resolved, in the
# order the calls arrived.
# shellcheck disable=SC2016
replies_cmd=(bash -c 'status=0
  "$1/reply-to-fixed-bot-comments.sh" PostHog/posthog 98865 "$2" >/dev/null 2>&1 || status=$?
  grep -oE "^body=.*|comments/[0-9]+/replies|threadId=[A-Za-z0-9_]+" "$MOCK_CALLS" || true
  exit "$status"' bash "$scripts")
fixed="$sandbox/fixed"

printf '111\tthe deploy script now quotes the expansion.\n333\tthe README now names the default.\n444\tthe retry now stops after three attempts.\n111\ta later pass repeated this comment.\n' >"$fixed"
assert_run_state 'reply to and resolve only the bot comments, once each' pending 0 '' \
  $'comments/111/replies\nbody=Fixed in abc1234: the deploy script now quotes the expansion.\ncomments/444/replies\nbody=Fixed in abc1234: the retry now stops after three attempts.\nthreadId=PRRT_111\nthreadId=PRRT_444' \
  "${replies_cmd[@]}" "$fixed"

printf '333\tthe README now names the default.\n' >"$fixed"
assert_run_state 'post nothing and resolve nothing for a human comment' pending 0 '' '' \
  "${replies_cmd[@]}" "$fixed"

printf '777\tthe resolved thread gets nothing.\n666\tno thread opens with this comment.\n' >"$fixed"
assert_run_state 'post nothing for a resolved thread or an unknown comment' pending 0 '' '' \
  "${replies_cmd[@]}" "$fixed"

assert_run_state 'post nothing when the review threads cannot be read' threads_failure 1 '' '' \
  "${replies_cmd[@]}" "$fixed"

printf '555\tthe deploy script now quotes the expansion.\n' >"$fixed"
assert_run_state 'leave a thread open when its reply fails to post' pending 1 '' \
  $'comments/555/replies\nbody=Fixed in abc1234: the deploy script now quotes the expansion.' \
  "${replies_cmd[@]}" "$fixed"

printf 'not-an-id\tthis line is malformed.\n' >"$fixed"
assert_run_state 'skip and flag a line without a numeric comment id' pending 1 '' '' \
  "${replies_cmd[@]}" "$fixed"

printf '111\n' >"$fixed"
assert_run_state 'skip and flag a line without a sentence' pending 1 '' '' \
  "${replies_cmd[@]}" "$fixed"

printf '111\tthe deploy script now quotes the expansion.\n' >"$fixed"
assert_run_state 'fail when a replied thread does not resolve' resolve_failure 1 '' \
  $'comments/111/replies\nbody=Fixed in abc1234: the deploy script now quotes the expansion.\nthreadId=PRRT_111' \
  "${replies_cmd[@]}" "$fixed"

print_results
