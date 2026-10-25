#!/bin/bash
# Look up each PR with `gh pr view` and print one row per PR.
#
# Usage: standup-pr-view.sh <json fields> <jq filter> <owner/repo#number>...
#
# Output: one "<owner/repo#number><TAB><filter result>" line per PR.
#
# A failed lookup prints an error that names the PR on stderr. The script still
# looks up the remaining PRs, then exits non-zero. Without that exit status, the
# standup would read the PR's missing row as a PR with no reviews and drop it
# from the notes.

set -euo pipefail

if [[ $# -lt 3 ]]; then
  echo "Usage: standup-pr-view.sh <json fields> <jq filter> <owner/repo#number>..." >&2
  exit 64
fi

fields="$1"
filter="$2"
shift 2

failed=0
for pr in "$@"; do
  repo="${pr%%#*}"
  num="${pr##*#}"
  if row=$(gh pr view "$num" --repo "$repo" --json "$fields" --jq "$filter"); then
    printf '%s\t%s\n' "$pr" "$row"
  else
    echo "Error: gh pr view failed for $pr" >&2
    failed=1
  fi
done

exit "$failed"
