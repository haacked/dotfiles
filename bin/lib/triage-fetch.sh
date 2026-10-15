#!/usr/bin/env bash
# Parallel fetch helpers shared by bin/triage-flags-pr-candidates,
# bin/triage-bot-pr-queue, and bin/triage-issue-queue. Each fetch writes its
# result to its own file in a directory. Parallel writers to one stream can
# interleave long lines. A fetch that fails leaves no .json file, which is how
# callers find the failures.
#
# Usage: source "$SCRIPT_DIR/lib/triage-fetch.sh"; export -f fetch_pr_files

FLAGS_TEAM="team-feature-flags"
# The PM is on the GitHub team but reviews no code.
FLAGS_NON_REVIEWERS='["rubychilds"]'

# Writes {number, files} to DIR/NUMBER.json. gh pr view returns at most 100
# files. The paginated REST endpoint returns every path.
fetch_pr_files() { # repo dir number
  local repo="$1" dir="$2" number="$3"
  if gh api "repos/$repo/pulls/$number/files" --paginate --jq '.[].filename' > "$dir/$number.out" 2>/dev/null; then
    jq -Rnc --argjson number "$number" '{number: $number, files: [inputs]}' < "$dir/$number.out" > "$dir/$number.json"
  fi
}

# Writes the team's logins to DIR/team.json and the team minus
# FLAGS_NON_REVIEWERS to DIR/roster.json. Both hold null when the fetch fails.
fetch_roster() { # dir
  if gh api --paginate "orgs/PostHog/teams/$FLAGS_TEAM/members" --jq '.[].login' > "$1/team.txt" 2>/dev/null; then
    jq -Rnc '[inputs]' < "$1/team.txt" > "$1/team.json"
    jq -c --argjson exclude "$FLAGS_NON_REVIEWERS" '. - $exclude' "$1/team.json" > "$1/roster.json"
  else
    echo "Could not fetch the $FLAGS_TEAM roster." >&2
    echo null > "$1/team.json"
    echo null > "$1/roster.json"
  fi
}

# Writes {path, logins} to a new .json file in DIR, with one login per commit
# that touched PATH since SINCE.
fetch_committers() { # repo since dir path
  local repo="$1" since="$2" dir="$3" path="$4" out
  out=$(mktemp "$dir/XXXXXX")
  if gh api -X GET "repos/$repo/commits" -f path="$path" -f since="$since" -F per_page=100 --paginate \
       --jq '.[] | .author.login // empty' > "$out" 2>/dev/null; then
    jq -Rnc --arg path "$path" '{path: $path, logins: [inputs]}' < "$out" > "$out.json"
  fi
}

# Writes {LOGIN: N} to DIR/LOGIN.json, where N is the GitHub search result
# count for QUERY_PREFIX followed by LOGIN.
fetch_search_count() { # dir query-prefix login
  local dir="$1" query="$2$3" login="$3"
  if gh api -X GET search/issues -f q="$query" -F per_page=1 --jq .total_count > "$dir/$login.out" 2>/dev/null; then
    jq -nc --arg login "$login" --slurpfile n "$dir/$login.out" '{($login): $n[0]}' > "$dir/$login.json"
  fi
}

# Runs fetch_roster on DIR, then fetch_search_count for each reviewer into
# LOAD_DIR. The caller must export fetch_search_count for xargs.
fetch_roster_and_load() { # dir load-dir query-prefix
  fetch_roster "$1"
  jq -r '.[]?' "$1/roster.json" \
    | xargs -r -P 15 -n 1 bash -c 'fetch_search_count "$@"' _ "$2" "$3"
}

# Prints the date N days ago in FORMAT, in UTC, on BSD or GNU date.
days_ago() { # n format
  date -u -v-"$1"d +"$2" 2>/dev/null || date -u -d "$1 days ago" +"$2"
}

# Concatenates the .json results in DIR into DIR.jsonl for jq --slurpfile.
collect_json() { # dir
  find "$1" -name '*.json' -exec cat {} + > "$1.jsonl"
}
