#!/usr/bin/env bash
# ran-report.sh - Which workflow steps have run against this branch
#
# Usage: ran-report.sh [--json]
#
# Reads the log ai/bin/log-command.sh writes, the working tree, and the branch's
# PR, and renders a checklist of the pipeline, marking each step fresh, stale,
# missing, running, or not yet due. See helpers/ran-verdict.jq for how
# staleness is decided.
#
# Output formats:
#   Default: a human-readable checklist
#   --json:  the raw verdict from ran-verdict.jq
#
# Exit codes:
#   Default: 0 on success, 1 on any error (missing jq, no GitHub origin,
#            detached HEAD, no resolvable base branch, and so on)
#   --json:  always 0 (errors reported in the "error" field)
#
# Environment:
#   RAN_ATTRIBUTION_WINDOW  seconds a command can claim a commit (default 3600)
#   RAN_NOW                 epoch seconds that clock times render against
#
# The report makes one GitHub call, for the PR, its checks, and its review
# threads. When that call fails, the rows that read GitHub read the log instead.
# The report names those rows. Base resolution stays local. A wrong base fails safe: extra commits
# attribute to "manual", which marks steps stale and re-runs them. A base that
# cannot be resolved at all is an error, not an empty commit list: with nothing
# to attribute, every logged step would report fresh.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERDICT_JQ="${SCRIPT_DIR}/helpers/ran-verdict.jq"

JSON_MODE=false
while [ $# -gt 0 ]; do
    case "$1" in
        --json) JSON_MODE=true; shift ;;
        -h | --help) sed -n '2,${/^#/!q; s/^# \{0,1\}//p;}' "$0"; exit 0 ;;
        *) shift ;;
    esac
done

fail() {
    if [ "$JSON_MODE" = true ]; then
        printf '{"error":"%s"}\n' "$1"
        exit 0
    fi
    echo "$1" >&2
    exit 1
}

command -v jq > /dev/null 2>&1 || fail "Required command not found: jq"

# shellcheck source=../../../helpers/command-steps.sh
. "${SCRIPT_DIR}/../../../helpers/command-steps.sh" || fail "Cannot load command-steps.sh"
# shellcheck source=../../../helpers/repo-context.sh
. "${SCRIPT_DIR}/../../../helpers/repo-context.sh" || fail "Cannot load repo-context.sh"

derive_org_repo || fail "No GitHub origin remote"
repo_context_is_path_safe || fail "Unsafe org or repo name in the origin URL"

branch=$(resolve_branch_name network) ||
    fail "No branch to report on: HEAD is detached, RAN_BRANCH is unset, and no PR has this commit as its head"

# isCrossRepository drops a fork's PR that happens to use the same branch name.
# An open PR wins over the newest closed or merged one. Each review thread
# fetches only its latest comment, whose author and time are all the report reads.
# shellcheck disable=SC2016 # The $ names are GraphQL variables.
PR_QUERY='query($owner: String!, $name: String!, $head: String!) {
  viewer { login }
  repository(owner: $owner, name: $name) {
    pullRequests(headRefName: $head, first: 5, orderBy: {field: CREATED_AT, direction: DESC}) {
      nodes {
        number state isDraft isCrossRepository headRefOid
        commits(last: 1) { nodes { commit { statusCheckRollup { state } } } }
        reviewThreads(first: 100) {
          pageInfo { hasNextPage }
          nodes { isResolved comments(last: 1) { nodes { createdAt author { login } } } }
        }
      }
    }
  }
}'

# GIT_OPTIONAL_LOCKS=0 stops the backgrounded status from writing index.lock,
# which would make a commit that runs at the same time fail.
work_dir=$(mktemp -d) || fail "Could not create a temporary directory"
trap 'rm -rf "$work_dir"' EXIT
GH_PAGER='' gh api graphql -f query="$PR_QUERY" \
    -f owner="$REPO_ORG" -f name="$REPO_REPO" -f head="$branch" \
    > "${work_dir}/pr.json" 2> /dev/null &
pr_lookup_pid=$!
GIT_OPTIONAL_LOCKS=0 git status --porcelain > "${work_dir}/status" 2> /dev/null &
status_pid=$!

head_sha=$(git rev-parse --short HEAD 2> /dev/null) || fail "No commits on this branch"
head_full=$(git rev-parse HEAD)
log_file=$(command_log_path "$REPO_ORG" "$REPO_REPO" "$branch") || fail "Branch name has no safe log filename"

# Tiers 1-2 of bin/lib/git-default-branch.sh, inlined: those two are local and
# the rest of that helper probes the network.
base_ref=$(git symbolic-ref --quiet --short refs/remotes/origin/HEAD 2> /dev/null)
if [ -z "$base_ref" ]; then
    for candidate in origin/main origin/master; do
        if git show-ref --verify --quiet "refs/remotes/${candidate}" 2> /dev/null; then
            base_ref="$candidate"
            break
        fi
    done
fi
merge_base=$(git merge-base HEAD "$base_ref" 2> /dev/null)
[ -n "$merge_base" ] || fail "Could not resolve a base branch to measure this branch against"

# A rebase or an amend gives a commit a new sha and a new committer time. By
# that time alone, a rebased commit lands after every logged command and counts
# as made by hand. A commit whose patch-id matches a commit the branch held
# earlier keeps the earliest committer time that patch had. The branch's reflog
# and the logged shas name those earlier commits. A commit that matches nothing
# keeps its own time and marks the steps before it stale. Nobody has reviewed a
# patch that a rebase or amend changed. `--verbatim` keeps whitespace in the
# patch-id, so an amend that only re-indents code also matches nothing.
branch_history_json() {
    local current earlier ids
    current=$(git log --reverse --format='%H %h %at %ct' "${merge_base}..HEAD" 2> /dev/null)
    # cat-file drops logged shas this clone lacks, which would make git log fail.
    earlier=$(
        {
            git reflog --format=%H "refs/heads/${branch}" 2> /dev/null
            jq -r '.sha // empty' "$log_file" 2> /dev/null
        } | git cat-file --batch-check='%(objectname) %(objecttype)' |
            awk '$2 == "commit" { print $1 }' |
            git log --stdin --no-merges --format='%H %ct' ^HEAD "^${base_ref}" 2> /dev/null
    )
    ids=$(printf '%s\n%s\n' "$current" "$earlier" | cut -d' ' -f1 |
        git diff-tree --stdin -p | git patch-id --verbatim)
    jq -n -c --arg current "$current" --arg earlier "$earlier" --arg ids "$ids" '
      def fields($text): $text | split("\n") | map(select(length > 0) | split(" "));
      (fields($ids) | map({key: .[1], value: .[0]}) | from_entries) as $id_of
      | (fields($current) | map({full: .[0], sha: .[1], at: (.[2] | tonumber), ct: (.[3] | tonumber)})) as $commits
      | (fields($earlier) | map({full: .[0], ct: (.[1] | tonumber), id: ($id_of[.[0]] // "")})) as $earlier
      | (reduce ($earlier[] | select(.id != "")) as $e ({}; .[$e.id] = ([.[$e.id] // empty, $e.ct] | min)))
        as $first_seen
      | ($commits | map(select($id_of[.full] != null) | {key: $id_of[.full], value: .sha}) | from_entries)
        as $sha_with_id
      | {commits: [$commits[]
                   | $first_seen[$id_of[.full] // ""] as $seen
                   | {sha, ts: ([$seen // empty, .ct] | min), rewritten: ($seen == null and .at != .ct)}],
         renamed: ($earlier | map(select($sha_with_id[.id] != null) | {key: .full, value: $sha_with_id[.id]})
                   | from_entries),
         gone: [$earlier[] | select($sha_with_id[.id] == null) | .full]}'
}

history_json=$(branch_history_json)
[ -n "$history_json" ] || fail "Could not read the branch's commits"

entries_json=$(jq -s -c . "$log_file" 2> /dev/null)
[ -n "$entries_json" ] || entries_json='[]'

wait "$status_pid"
dirty=$(wc -l < "${work_dir}/status" | tr -d ' ')

github=false
if wait "$pr_lookup_pid" &&
    pr_json=$(jq -c '
        .data.viewer.login as $viewer
        | .data.repository.pullRequests.nodes
        | map(select(.isCrossRepository | not))
        | (map(select(.state == "OPEN")) + .)[0]
        | if . == null then null
          else {number, state, draft: .isDraft, head: .headRefOid,
                ci: .commits.nodes[0].commit.statusCheckRollup.state,
                more_threads: (.reviewThreads.pageInfo.hasNextPage // false),
                unanswered: [.reviewThreads.nodes[] | select(.isResolved | not)
                             | .comments.nodes[0] | select(.author.login != $viewer)
                             | .createdAt | fromdateiso8601]}
          end' "${work_dir}/pr.json" 2> /dev/null) &&
    [ -n "$pr_json" ]; then
    github=true
else
    pr_json=null
fi

if [ "$pr_json" != null ]; then
    pr_head=$(printf '%s' "$pr_json" | jq -r .head)
    ahead=null
    if [ "$pr_head" = "$head_full" ]; then
        ahead=0
        pr_head_short="$head_sha"
    else
        pr_head_short=$(git rev-parse --short "$pr_head" 2> /dev/null)
        if git merge-base --is-ancestor "$pr_head" HEAD 2> /dev/null; then
            ahead=$(git rev-list --count "${pr_head}..HEAD")
        fi
    fi
    pr_json=$(printf '%s' "$pr_json" | jq -c --arg head "$pr_head_short" --argjson ahead "$ahead" \
        '. + {head: $head, ahead: $ahead}')
fi

verdict=$(jq -n -c -L "${SCRIPT_DIR}/helpers" \
    --arg head "$head_sha" \
    --arg branch "$branch" \
    --argjson window "${RAN_ATTRIBUTION_WINDOW:-3600}" \
    --argjson steps "$(command_step_table_json)" \
    --argjson history "$history_json" \
    --argjson entries "$entries_json" \
    --argjson dirty "$dirty" \
    --argjson github "$github" \
    --argjson pr "$pr_json" \
    -f "$VERDICT_JQ" 2> /dev/null)
[ -n "$verdict" ] || fail "Could not compute the report"

if [ "$JSON_MODE" = true ]; then
    printf '%s\n' "$verdict"
    exit 0
fi

printf 'Branch %s @ %s\n\n' "$branch" "$head_sha"
printf '%s' "$verdict" | jq -r -L "${SCRIPT_DIR}/helpers" --argjson now "${RAN_NOW:-null}" '
  include "text";
  ($now // now) as $now
  | def marker: {fresh: "✓", stale: "⚠", missing: "✗", running: "…"}[.] // "·";
    def day: strflocaltime("%Y-%m-%d");
    # A bare clock time reads as today, so a run from an earlier day names the day.
    def clock:
      fromdateiso8601 as $t
      | if ($t | day) == ($now | day) then $t | strflocaltime("%H:%M")
        elif $now - $t < 6 * 86400 then $t | strflocaltime("%a %H:%M")
        else $t | strflocaltime("%b %d %H:%M")
        end;
    # Reasons on a row with no run explain why the step is missing. Reasons on a
    # row with a run explain why it is stale.
    def why:
      if (.reasons | length) == 0 then ""
      else " (\(if .status == "stale" then "stale: " else "" end)\(.reasons | join("; ")))"
      end;
  ( .rows[]
    | . as $r
    | ((if ($r.commits // 0) > 0 then plural($r.commits; "commit")
       elif $r.detail != null then $r.detail
       elif $r.at == null then (if $r.status == "missing" then "never run" else "not yet run" end)
       else ($r.at | clock) + "  @ " + ($r.sha // "-")
            + (if $r.gone then ", no longer on the branch" else "" end)
       end) + ($r | why)) as $detail
    | "  \($r.status | marker) \($r.step + (" " * (20 - ($r.step | length))))\($detail)"
  ),
  "",
  (if (.outstanding | length) == 0 then "Nothing outstanding."
   else "\(plural(.outstanding | length; "step")) outstanding: \(.outstanding | join(", "))" end),
  (if (.extras | length) > 0 then "Also logged: \(.extras | join(", "))" else empty end),
  (if (.fell_back | length) > 0
   then "GitHub did not answer, so these rows read only the log: \(.fell_back | join(", "))."
   else empty end)
'
