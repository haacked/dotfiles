#!/usr/bin/env bash
set -euo pipefail

DEFAULT_TEAM=team-feature-flags

usage() {
  echo "Usage: $(basename "$0") [-o ORG] [-t [TEAM]] [-r [TEAM]] [-h]"
  echo ""
  echo "Open GitHub search for open PRs by team."
  echo ""
  echo "Options:"
  echo "  -o ORG    GitHub organization (default: PostHog)"
  echo "  -t TEAM   Filter by author team (default: $DEFAULT_TEAM)"
  echo "  -r TEAM   Filter by review-requested team"
  echo "  -h        Show this help message"
  echo ""
  echo "Examples:"
  echo "  $(basename "$0")              # PRs authored by $DEFAULT_TEAM"
  echo "  $(basename "$0") -t foo       # PRs authored by foo"
  echo "  $(basename "$0") -r foo       # PRs where foo is requested reviewer"
  echo "  $(basename "$0") -t foo -r bar  # PRs by foo, review requested from bar"
  echo "  $(basename "$0") -t -r        # PRs by $DEFAULT_TEAM, review from $DEFAULT_TEAM"
  exit 0
}

ORG=PostHog
AUTHOR_TEAM=""
REVIEW_TEAM=""

while [[ $# -gt 0 ]]; do
  case $1 in
    -o)
      ORG="$2"
      shift 2
      ;;
    -t)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        AUTHOR_TEAM="$DEFAULT_TEAM"
        shift
      else
        AUTHOR_TEAM="$2"
        shift 2
      fi
      ;;
    -r)
      if [[ -z "${2:-}" || "$2" == -* ]]; then
        REVIEW_TEAM="$DEFAULT_TEAM"
        shift
      else
        REVIEW_TEAM="$2"
        shift 2
      fi
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage
      ;;
  esac
done

# Default to author mode with default team if nothing specified
if [[ -z "$AUTHOR_TEAM" && -z "$REVIEW_TEAM" ]]; then
  AUTHOR_TEAM="$DEFAULT_TEAM"
fi

get_members() {
  local team=$1
  gh api "orgs/$ORG/teams/$team/members" --paginate --jq '.[].login'
}

q="type:pr is:open org:$ORG"

# Add author filters
if [[ -n "$AUTHOR_TEAM" ]]; then
  mapfile -t MEMBERS < <(get_members "$AUTHOR_TEAM")
  if [[ ${#MEMBERS[@]} -eq 0 ]]; then
    echo "No members found for team $ORG/$AUTHOR_TEAM" >&2
    exit 1
  fi
  for u in "${MEMBERS[@]}"; do
    q+=" author:$u"
  done
fi

# Add review-requested filters
if [[ -n "$REVIEW_TEAM" ]]; then
  mapfile -t REVIEWERS < <(get_members "$REVIEW_TEAM")
  if [[ ${#REVIEWERS[@]} -eq 0 ]]; then
    echo "No members found for team $ORG/$REVIEW_TEAM" >&2
    exit 1
  fi
  for u in "${REVIEWERS[@]}"; do
    q+=" review-requested:$u"
  done
fi

# URL-encode the query and open in browser
encoded_q=$(python3 -c "import urllib.parse; print(urllib.parse.quote('$q'))")
open "https://github.com/search?q=$encoded_q"
