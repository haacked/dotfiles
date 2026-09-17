#!/usr/bin/env bash
# PostHog Desktop uploads this skill folder on its own to a cloud sandbox that holds
# no clone of this repo, so every script the skill runs has to resolve inside the
# folder. This test copies the folder elsewhere, points DOTFILES_DIR at a directory
# that does not exist, and runs each entry point under env -i from an unrelated
# working directory. A script that names a path outside the folder fails here rather
# than in the sandbox. A bare command name is the exception on a developer's machine,
# where the repo's own bin directory is still on PATH.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=/dev/null
source "${SCRIPT_DIR}/../../../../helpers/portable-skills.sh"

sandbox=$(mktemp -d)
trap 'rm -rf "$sandbox"' EXIT
mkdir -p "$sandbox/bin" "$sandbox/home" "$sandbox/unrelated"
cp -R "$SCRIPT_DIR/../.." "$sandbox/skill"

# Nothing below may shell out to git, so every invocation is a failure.
cat >"$sandbox/bin/git" <<'MOCK'
#!/usr/bin/env bash
echo "Unexpected git arguments: $*" >&2
exit 1
MOCK

cat >"$sandbox/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
projection='.'
for ((i = 1; i <= $#; i++)); do
  if [[ "${!i}" == '--jq' || "${!i}" == '-q' ]]; then
    next=$((i + 1))
    projection="${!next}"
  fi
done

threads='{"data":{"repository":{"pullRequest":{"reviewThreads":{"nodes":[
  {"id":"PRRT_bot","isResolved":false,"isOutdated":false,"path":"bin/deploy.sh","line":12,
   "comments":{"nodes":[{"databaseId":111,"path":"bin/deploy.sh","line":12,"body":"Quote this expansion.","diffHunk":"@@ -10,3 +10,3 @@","author":{"login":"copilot-pull-request-reviewer","__typename":"Bot"}}]}},
  {"id":"PRRT_done","isResolved":true,"isOutdated":false,"path":"bin/deploy.sh","line":30,
   "comments":{"nodes":[{"databaseId":222,"path":"bin/deploy.sh","line":30,"body":"Already fixed.","diffHunk":"@@ -28,3 +28,3 @@","author":{"login":"reviewer","__typename":"User"}}]}},
  {"id":"PRRT_human","isResolved":false,"isOutdated":false,"path":"README.md","line":4,
   "comments":{"nodes":[{"databaseId":333,"path":"README.md","line":4,"body":"Name the default.","diffHunk":"@@ -2,3 +2,3 @@","author":{"login":"reviewer","__typename":"User"}}]}}
],"pageInfo":{"hasNextPage":false,"endCursor":null}}}}}}'

if [[ "$1 $2" == 'pr view' ]]; then
  [[ "$*" == *'98865'* && "$*" == *'--repo PostHog/posthog'* ]]
  echo '{"headRefName":"contributor-feature","headRefOid":"1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3"}' | jq -r "$projection"
elif [[ "$1 $2" == 'api graphql' ]]; then
  [[ "$*" == *'owner=PostHog'* ]]
  if [[ "$*" == *reviewThreads* ]]; then
    [[ "$*" == *'repo=posthog'* && "$*" == *'number=98865'* ]]
    echo "$threads" | jq -r "$projection"
  else
    [[ "$*" == *'name=posthog'* && "$*" == *'pr=98865'* ]]
    echo '{"data":{"repository":{"pullRequest":{"reviewRequests":{"nodes":[{"requestedReviewer":{"__typename":"Bot","login":"greptile-apps[bot]"}},{"requestedReviewer":{"__typename":"User","login":"copilot-pull-request-reviewer[bot]"}},{"requestedReviewer":{"__typename":"User","login":"human"}},{"requestedReviewer":{"__typename":"Team","name":"reviewers"}}]}}}}}' | jq -r "$projection"
  fi
elif [[ "$1" == api && "$*" == *'repos/PostHog/posthog/'* ]]; then
  case "$*" in
    *'/timeline?per_page=100'*)
      echo '[[{"event":"labeled","label":{"name":"reviewhog"},"created_at":"2026-09-15T10:00:00Z"}]]'
      ;;
    *'/reviews?per_page=100'*|*'/comments?per_page=100'*) echo '[[]]' ;;
    *'repos/PostHog/posthog/issues/98865 --jq'*)
      echo '{"labels":[{"name":"reviewhog"}]}' | jq -r "$projection"
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
  local description="$1" expected_status="$2" jq_filter="$3" expected="$4"
  shift 4
  local status=0 actual
  env -i HOME="$sandbox/home" DOTFILES_DIR="$sandbox/missing" PATH="$sandbox/bin:$PATH" \
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
pr_url='https://github.com/PostHog/posthog/pull/98865'

missing=()
while read -r _ destination; do
  [[ -f "$scripts/$destination" ]] || missing+=("$destination")
done < <(portable_skill_helpers address-pr-reviews)

if [[ "${#missing[@]}" -eq 0 ]]; then
  passes=$((passes + 1))
else
  echo "FAIL: the copied skill folder is missing vendored helpers: ${missing[*]}"
  failures=$((failures + 1))
fi

detected='{"pr_number":98865,"org":"posthog","repo":"posthog","head_branch":"contributor-feature","head_sha":"1f0a2b3c4d5e6f708192a3b4c5d6e7f809a1b2c3","error":null}'
assert_run 'detect a PR URL from the copied skill' 0 '.' "$detected" \
  "$scripts/detect-pr.sh" --json "$pr_url"
assert_run 'report an unresolvable target in the error field' 0 '.error != null' true \
  "$scripts/detect-pr.sh" --json not-a-pr

# gh-resolve-threads announces its fetch through log_info, which writes to stdout, so
# the JSON document starts at the first line opening a brace.
# shellcheck disable=SC2016
assert_run 'resolve a thread by comment id under dry run' 0 \
  '{comment: .threads[0].commentId, resolved: .resolvedCount, unresolved: .totalUnresolved, dry: .dryRun}' \
  '{"comment":111,"resolved":0,"unresolved":2,"dry":true}' \
  bash -c 'set -o pipefail; "$1/gh-resolve-threads" "$2" --comment-id 111 --dry-run --json | sed -n "/^{/,\$p"' \
  bash "$scripts" "$pr_url"

assert_run 'fetch unresolved comments through the bundled libraries' 0 \
  '[.[] | {id, author, is_bot}]' \
  '[{"id":111,"author":"copilot-pull-request-reviewer","is_bot":true},{"id":333,"author":"reviewer","is_bot":false}]' \
  "$scripts/fetch-unaddressed-comments.sh" PostHog/posthog 98865

# record-dismissed-comment.sh is the only caller of lib/fs.sh, so nothing else here
# proves that copy arrived. It reads the comment body from stdin and writes the state
# file under HOME, which the wrapper then prints for the filter to read.
# shellcheck disable=SC2016
assert_run 'record a dismissed comment through the bundled libraries' 0 \
  '[.dismissed_comments[].body_preview]' '["Prefer a named constant here."]' \
  bash -c 'printf "%s" "$2" | "$1/record-dismissed-comment.sh" acme/widgets 123 >/dev/null &&
    cat "$HOME/.local/state/copilot-review-loop/acme-widgets-123.json"' \
  bash "$scripts" 'Prefer a named constant here.'

pending_filter='{pending: (.pending | sort_by(.reviewer)), warnings}'
pending_verdict='{"pending":[{"reviewer":"copilot-pull-request-reviewer[bot]","signal":"requested_reviewer","since":null},{"reviewer":"greptile-apps[bot]","signal":"requested_reviewer","since":null},{"reviewer":"reviewhog","signal":"label","since":"2026-09-15T10:00:00Z"}],"warnings":[]}'
assert_run 'compute pending reviews from the copied helpers' 0 "$pending_filter" "$pending_verdict" \
  "$scripts/check-pending-reviews.sh" PostHog/posthog 98865

assert_run 'skip the step record when the repo helper is absent' 0 '' '' \
  "$scripts/record-step.sh" address-pr-reviews

explanation_lines=$(wc -l <"$sandbox/stderr" | tr -d ' ')
if [[ "$explanation_lines" == 1 ]]; then
  passes=$((passes + 1))
else
  echo "FAIL: explain the skipped step record in exactly one line (got $explanation_lines)"
  failures=$((failures + 1))
fi

echo "$passes passed, $failures failed"
[[ "$failures" -eq 0 ]]
