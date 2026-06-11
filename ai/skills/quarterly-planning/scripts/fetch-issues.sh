#!/usr/bin/env bash
# Fetch open issues for the configured labels, union and de-duplicate them, and
# emit a JSON array sorted by engagement (reactions + comments).
#
# Usage: fetch-issues.sh ["label-a label-b …"]
#   With no argument, uses $QPLAN_LABELS from config.sh.
#
# Per-label coverage (counts, missing labels) is written to stderr so the caller
# can surface it; the deduplicated issue JSON is written to stdout.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

LABELS="${1:-$QPLAN_LABELS}"
FIELDS="number,title,url,labels,createdAt,updatedAt,comments,reactionGroups,milestone,assignees,author"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
wrote_any=0

echo "Label coverage in ${QPLAN_REPO} (open issues):" >&2
for L in $LABELS; do
  exists="$(gh label list --repo "$QPLAN_REPO" --search "$L" --json name \
    --jq "any(.name == \"$L\")" 2>/dev/null || echo false)"
  if [ "$exists" != "true" ]; then
    echo "  ! ${L} — label not found, skipped" >&2
    continue
  fi
  out="$tmp/$(echo "$L" | tr '/' '_').json"
  gh issue list --repo "$QPLAN_REPO" --state open --label "$L" \
    --limit "$QPLAN_ISSUE_LIMIT" --json "$FIELDS" > "$out" 2>/dev/null
  echo "  + ${L} — $(jq 'length' "$out") open" >&2
  wrote_any=1
done

if [ "$wrote_any" -eq 0 ]; then
  echo "[]"
  exit 0
fi

# Union by issue number; flatten labels; compute a single reaction total; sort
# by engagement so the highest-signal issues surface first for theme grouping.
jq -s '
  add
  | unique_by(.number)
  | map({
      number,
      title,
      url,
      labels: [.labels[].name],
      comments: (.comments | length),
      reactions: ([.reactionGroups[]?.users.totalCount] | add // 0),
      createdAt,
      updatedAt,
      milestone: (.milestone.title // null),
      assignees: [.assignees[].login],
      author: (.author.login // null)
    })
  | sort_by(-(.reactions + .comments))
' "$tmp"/*.json
