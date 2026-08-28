#!/usr/bin/env bash
# ran-report.sh - Which workflow steps have run against this branch
#
# Usage: ran-report.sh [--json]
#
# Reads the log ai/bin/log-command.sh writes and renders a checklist of the
# pipeline, marking each step fresh, stale, missing, or not yet due. See
# helpers/ran-verdict.jq for how staleness is decided.
#
# Output formats:
#   Default: a human-readable checklist
#   --json:  the raw verdict from ran-verdict.jq
#
# Exit codes:
#   Default: 0 on success, 1 when there is no GitHub repo to report on and 1
#            when no base branch can be resolved
#   --json:  always 0 (errors reported in the "error" field)
#
# Base resolution is deliberately local-only. A wrong base fails safe: extra
# commits attribute to "manual", which marks steps stale and re-runs them.
# Paying gh and gt network calls to avoid that costs ~900ms on every report.
# A base that cannot be resolved at all is an error, not an empty commit list:
# with nothing to attribute, every logged step would report fresh.

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

branch=$(git branch --show-current 2> /dev/null)
[ -n "$branch" ] || fail "Detached HEAD: no branch to report on"
head_sha=$(git rev-parse --short HEAD 2> /dev/null) || fail "No commits on this branch"
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

commits_json=$(git log --reverse --format='{"sha":"%h","ts":%ct}' "${merge_base}..HEAD" 2> /dev/null | jq -s -c .)
[ -n "$commits_json" ] || commits_json='[]'

entries_json=$(jq -s -c . "$log_file" 2> /dev/null)
[ -n "$entries_json" ] || entries_json='[]'

verdict=$(jq -n -c \
    --arg head "$head_sha" \
    --arg branch "$branch" \
    --argjson window "${RAN_ATTRIBUTION_WINDOW:-3600}" \
    --argjson steps "$(command_step_table_json)" \
    --argjson commits "$commits_json" \
    --argjson entries "$entries_json" \
    -f "$VERDICT_JQ" 2> /dev/null)
[ -n "$verdict" ] || fail "Could not compute the report"

if [ "$JSON_MODE" = true ]; then
    printf '%s\n' "$verdict"
    exit 0
fi

printf 'Branch %s @ %s\n\n' "$branch" "$head_sha"
printf '%s' "$verdict" | jq -r '
  def plural(n; w): "\(n) \(w)\(if n == 1 then "" else "s" end)";
  def marker: {fresh: "✓", stale: "⚠", missing: "✗"}[.] // "·";
  ( .rows[]
    | . as $r
    | (if ($r.commits // 0) > 0 then plural($r.commits; "commit")
       elif $r.at == null then (if $r.status == "missing" then "never run" else "not yet run" end)
       else ($r.at | fromdateiso8601 | strflocaltime("%H:%M")) + "  @ " + ($r.sha // "-")
            + (if $r.status == "stale" then " (stale, commits since)" else "" end)
       end) as $detail
    | "  \($r.status | marker) \($r.step + (" " * (20 - ($r.step | length))))\($detail)"
  ),
  "",
  (if (.outstanding | length) == 0 then "Nothing outstanding."
   else "\(plural(.outstanding | length; "step")) outstanding: \(.outstanding | join(", "))" end),
  (if (.extras | length) > 0 then "Also logged: \(.extras | join(", "))" else empty end)
'
