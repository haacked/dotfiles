#!/usr/bin/env bash
# Parallel fetch helpers shared by bin/triage-flags-pr-candidates and
# bin/triage-bot-pr-queue. Each fetch writes its result to its own file in a
# directory. Parallel writers to one stream can interleave long lines. A fetch
# that fails leaves no .json file, which is how callers find the failures.
#
# Usage: source "$SCRIPT_DIR/lib/triage-fetch.sh"; export -f fetch_pr_files

# Writes {number, files} to DIR/NUMBER.json. gh pr view returns at most 100
# files. The paginated REST endpoint returns every path.
fetch_pr_files() { # repo dir number
  local repo="$1" dir="$2" number="$3"
  if gh api "repos/$repo/pulls/$number/files" --paginate --jq '.[].filename' > "$dir/$number.out" 2>/dev/null; then
    jq -Rnc --argjson number "$number" '{number: $number, files: [inputs]}' < "$dir/$number.out" > "$dir/$number.json"
  fi
}

# Concatenates the .json results in DIR into DIR.jsonl for jq --slurpfile.
collect_json() { # dir
  find "$1" -name '*.json' -exec cat {} + > "$1.jsonl"
}
