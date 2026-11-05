#!/bin/bash
# Write the standup notes on stdin to the archive file.
#
# Usage: standup-save.sh <new_file_path> < notes
#
# The next run uses this file's modified time as its merge cutoff, so a PR the
# notes leave out never appears in any standup. The script writes the file only
# when both of these hold, and otherwise exits 1 without touching it:
#   - The last standup-gather.sh run succeeded, and standup-find.sh still
#     returns the previous notes that set that run's cutoff. A save, or any
#     other change to the newest notes file, makes the gather stale.
#   - The notes contain every URL in that gather's must_list.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/state.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: standup-save.sh <new_file_path> < notes" >&2
  exit 64
fi

path="$1"
notes=$(cat)

refuse() {
  echo "Error: not writing ${path}: $1" >&2
  exit 1
}

[[ -f "$STANDUP_GATHER" ]] ||
  refuse "standup-gather.sh has not succeeded since its last run started. Report the error it printed."

[[ "$(jq -r .basis "$STANDUP_GATHER")" == "$("${SCRIPT_DIR}/standup-find.sh")" ]] ||
  refuse "the newest notes file changed after standup-gather.sh ran. Run standup-gather.sh again."

missing=$(jq -r --arg notes "$notes" '
  ($notes | [scan("https://github\\.com/[^/\\s]+/[^/\\s]+/pull/[0-9]+")]) as $listed
  | .must_list - $listed | .[]' "$STANDUP_GATHER")
[[ -z "$missing" ]] || refuse "the notes leave out these PRs, which the next run would never report:
${missing}"

mkdir -p "$(dirname "$path")"
printf '%s\n' "$notes" > "$path"
