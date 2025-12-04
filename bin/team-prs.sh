#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $(basename "$0") [-o ORG] [-t TEAM] [-h]"
  echo ""
  echo "Open GitHub search for open PRs authored by team members."
  echo ""
  echo "Options:"
  echo "  -o ORG    GitHub organization (default: PostHog)"
  echo "  -t TEAM   Team slug (default: team-feature-flags)"
  echo "  -h        Show this help message"
  exit 0
}

ORG=PostHog
TEAM=team-feature-flags

while getopts "o:t:h" opt; do
  case $opt in
    o) ORG="$OPTARG" ;;
    t) TEAM="$OPTARG" ;;
    h) usage ;;
    *) usage ;;
  esac
done

# Get team members
mapfile -t MEMBERS < <(
  gh api "orgs/$ORG/teams/$TEAM/members" --paginate --jq '.[].login'
)

if [[ ${#MEMBERS[@]} -eq 0 ]]; then
  echo "No members found for team $ORG/$TEAM" >&2
  exit 1
fi

q="type:pr is:open org:$ORG"
for u in "${MEMBERS[@]}"; do
  q+=" author:$u"
done

# URL-encode the query and open in browser
encoded_q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$q'))")
open "https://github.com/search?q=$encoded_q"
