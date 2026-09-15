#!/usr/bin/env bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/home" "$sandbox/unrelated"
cp -R "$SCRIPT_DIR/../.." "$sandbox/skill"

cat >"$sandbox/bin/git" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  'branch --show-current') echo local-review ;;
  'config branch.local-review.merge') echo refs/heads/contributor-feature ;;
  'config branch.local-review.pushRemote') echo contributor ;;
  'remote get-url contributor') echo git@github.com:Contributor/posthog.git ;;
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
elif [[ "$1 $2" == 'api graphql' ]]; then
  [[ "$*" == *'owner=PostHog'* && "$*" == *'name=posthog'* && "$*" == *'pr=98865'* ]]
  if [[ "$MOCK_STATE" == clear ]]; then
    echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Team","name":"reviewers"}},{"requestedReviewer":{"__typename":"User","login":"human"}}]}}}}}' | jq -r "$projection"
  else
    echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Bot","login":"greptile-apps[bot]"}},{"requestedReviewer":{"__typename":"User","login":"copilot-pull-request-reviewer[bot]"}},{"requestedReviewer":{"__typename":"User","login":"human"}},{"requestedReviewer":{"__typename":"Team","name":"reviewers"}},{"requestedReviewer":{"__typename":"Mannequin","login":"former-user"}},{"requestedReviewer":null}]}}}}}' | jq -r "$projection"
  fi
elif [[ "$1" == api && "$*" == *'repos/PostHog/posthog/'* ]]; then
  case "$*" in
    *'/timeline?per_page=100'*)
      echo '[[{"event":"labeled","label":{"name":"reviewhog"},"created_at":"2026-09-15T10:00:00Z"}]]'
      ;;
    *'/reviews?per_page=100'*|*'/comments?per_page=100'*) echo '[[]]' ;;
    *'repos/PostHog/posthog/issues/98865 --jq'*)
      [[ "$MOCK_STATE" != failure ]] || exit 1
      if [[ "$MOCK_STATE" == clear ]]; then
        echo '{"labels":[]}' | jq -r "$projection"
      else
        echo '{"labels":[{"name":"reviewhog"}]}' | jq -r "$projection"
      fi
      ;;
    *) echo "Unexpected API arguments: $*" >&2; exit 1 ;;
  esac
else
  echo "Unexpected gh arguments: $*" >&2
  exit 1
fi
MOCK
chmod +x "$sandbox/bin/git" "$sandbox/bin/gh"

passes=0
failures=0

assert_run() {
  local description="$1" mock_state="$2" expected_status="$3" jq_filter="$4" expected="$5"
  shift 5
  local status=0 actual
  : >"$sandbox/calls"
  env -i HOME="$sandbox/home" DOTFILES_DIR="$sandbox/missing" PATH="$sandbox/bin:$PATH" \
    MOCK_STATE="$mock_state" MOCK_CALLS="$sandbox/calls" \
    "$@" >"$sandbox/stdout" 2>"$sandbox/stderr" || status=$?
  actual=$(<"$sandbox/stdout")
  if [[ -n "$jq_filter" ]]; then
    actual=$(jq -cr "$jq_filter" "$sandbox/stdout") || actual='invalid JSON'
  fi
  if [[ "$status" == "$expected_status" && "$actual" == "$expected" ]]; then
    passes=$((passes + 1))
  else
    echo "FAIL: $description"
    echo "  expected exit $expected_status and '$expected'; got exit $status and '$actual'"
    cat "$sandbox/stderr"
    failures=$((failures + 1))
  fi
}

cd "$sandbox/unrelated"
scripts="$sandbox/skill/scripts"
target=$'PostHog\tposthog\tPostHog/posthog\t98865'

assert_run 'detect a PR URL from the copied skill' pending 0 '' "$target" \
  "$scripts/detect-pr.sh" https://github.com/PostHog/posthog/pull/98865
assert_run 'detect a PR number from the copied skill' pending 0 '' "$target" \
  "$scripts/detect-pr.sh" 98865
assert_run 'detect the renamed local branch in the correct fork' pending 0 '' "$target" \
  "$scripts/detect-pr.sh"

# shellcheck disable=SC2016
assert_run 'project GraphQL User and Bot reviewers and exclude teams' pending 0 '.' \
  '[{"login":"greptile-apps[bot]","type":"Bot"},{"login":"copilot-pull-request-reviewer[bot]","type":"User"},{"login":"human","type":"User"}]' \
  bash -c 'source "$1/lib/github.sh"; get_requested_reviewers PostHog/posthog 98865' bash "$scripts"

pending_filter='{pending: (.pending | sort_by(.reviewer)), warnings}'
pending_verdict='{"pending":[{"reviewer":"copilot-pull-request-reviewer[bot]","signal":"requested_reviewer","since":null},{"reviewer":"greptile-apps[bot]","signal":"requested_reviewer","since":null},{"reviewer":"reviewhog","signal":"label","since":"2026-09-15T10:00:00Z"}],"warnings":[]}'
assert_run 'compute pending reviews using the bundled libraries' pending 0 "$pending_filter" "$pending_verdict" \
  "$scripts/check-pending-reviews.sh" PostHog/posthog 98865
assert_run 'exit immediately when reviews have cleared' clear 0 '.' '{"pending":[],"warnings":[]}' \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --timeout 0
assert_run 'preserve the pending verdict on timeout' pending 2 "$pending_filter" "$pending_verdict" \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --timeout 0
assert_run 'fail after repeated fetch failures' failure 1 '' '' \
  "$scripts/wait-for-pending-reviews.sh" PostHog/posthog 98865 --interval 0 --timeout 30

failed_fetch_attempts=$(wc -l <"$sandbox/calls" | tr -d ' ')
if [[ "$failed_fetch_attempts" == 3 ]]; then
  passes=$((passes + 1))
else
  echo "FAIL: retry failed fetches exactly three times (got $failed_fetch_attempts)"
  failures=$((failures + 1))
fi

echo "$passes passed, $failures failed"
[[ "$failures" -eq 0 ]]
