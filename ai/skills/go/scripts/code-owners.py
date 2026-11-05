#!/usr/bin/env python3
"""Print the code owners whose review a PR needs, as GitHub reports them.

A PR needs a code owner's review only when a ruleset or branch protection rule on its
base branch requires code-owner review. GitHub requests code owners on other repositories
too, but there any approval that counts lets the PR merge.

When the base branch requires it, an owner counts when either:
  - GitHub requested the team's or person's review as a code owner, and the request is
    still open;
  - the repository's CODEOWNERS file names the team, and a member reviewed on the team's
    behalf, or names the person, and the person reviewed. The PR author never counts.

GitHub removes a request once the owner reviews, so the open requests alone miss an owner
who commented or requested changes. A review on a team's behalf does not say whether
GitHub requested the team as a code owner, and workflows also request teams. An owner
that CODEOWNERS never names cannot be a code owner, so the second rule leaves those teams
out. The second rule does not check which paths the owner owns, so a named owner who
reviewed stays counted after a push removes their files. That error refuses a merge and
never allows one. GitHub has already matched the PR's files against CODEOWNERS, so this
script reads that result instead of matching the patterns again.

Prints {"owners": [...], "pending": [...]}, both sorted. Teams appear as org/slug and
people as their login. pending lists the owners whose code-owner request is still open.
Exits 1 with {"error": ...} when GitHub cannot be read.
"""

import argparse
import importlib.util
import json
from pathlib import Path
import sys


# GitHub reads the first of these that exists, from the default branch.
QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    github: object(expression: "HEAD:.github/CODEOWNERS") { ... on Blob { text } }
    root: object(expression: "HEAD:CODEOWNERS") { ... on Blob { text } }
    docs: object(expression: "HEAD:docs/CODEOWNERS") { ... on Blob { text } }
    pullRequest(number: $number) {
      author { login }
      baseRefName
      baseRef { branchProtectionRule { requiresCodeOwnerReviews } }
      reviewRequests(first: 100) {
        nodes { asCodeOwner requestedReviewer { ... on Team { combinedSlug } ... on User { login } } }
      }
      reviews(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { author { login } onBehalfOf(first: 20) { nodes { combinedSlug } } }
      }
    }
  }
}
"""


def named_owners(codeowners):
    owners = set()
    for line in (codeowners or "").splitlines():
        if line.lstrip().startswith("#"):
            continue
        for token in line.split()[1:]:
            if token.startswith("#"):
                break
            owners.add(token.lstrip("@").lower())
    return owners


def base_branch(pages):
    return pages[0]["data"]["repository"]["pullRequest"]["baseRefName"]


def requires_code_owner_review(pr, rules):
    """Return whether branch protection or an active ruleset rule on the base branch requires code-owner review."""
    protection = (pr.get("baseRef") or {}).get("branchProtectionRule") or {}
    return bool(protection.get("requiresCodeOwnerReviews")) or any(
        rule.get("type") == "pull_request" and (rule.get("parameters") or {}).get("require_code_owner_review")
        for rule in rules
    )


def owners(pages, rules):
    """Return {"owners", "pending"} from the --paginate --slurp pages of QUERY and the base branch's rules."""
    repo = pages[0]["data"]["repository"]
    pr = repo["pullRequest"]
    if not requires_code_owner_review(pr, rules):
        return {"owners": [], "pending": []}
    pending = set()
    for node in pr["reviewRequests"]["nodes"]:
        reviewer = node.get("requestedReviewer") or {}
        name = reviewer.get("combinedSlug") or reviewer.get("login")
        if node.get("asCodeOwner") and name:
            pending.add(name)
    codeowners = next((blob["text"] for blob in (repo.get("github"), repo.get("root"), repo.get("docs")) if blob), "")
    named = named_owners(codeowners)
    author = ((pr.get("author") or {}).get("login") or "").lower()
    reviewed = set()
    for page in pages:
        for review in page["data"]["repository"]["pullRequest"]["reviews"]["nodes"]:
            login = (review.get("author") or {}).get("login") or ""
            if login and login.lower() != author and login.lower() in named:
                reviewed.add(login)
            for team in (review.get("onBehalfOf") or {}).get("nodes") or []:
                if team.get("combinedSlug") and team["combinedSlug"].lower() in named:
                    reviewed.add(team["combinedSlug"])
    return {"owners": sorted(pending | reviewed), "pending": sorted(pending)}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pr", help="PR number or URL; defaults to the current branch's PR")
    args = parser.parse_args(argv)
    # merge-gate.py imports this module, so it is loaded here rather than at import time.
    spec = importlib.util.spec_from_file_location("merge_gate", Path(__file__).resolve().parent / "merge-gate.py")
    merge_gate = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(merge_gate)
    try:
        url = merge_gate.gh_json("pr", "view", *([args.pr] if args.pr else []), "--json", "url")["url"]
        match = merge_gate.PR_URL.match(url or "")
        if not match:
            raise merge_gate.GateError(f"could not read the repository from PR URL {url!r}")
        result = owners(*merge_gate.fetch_code_owners(*match.groups()))
    except (merge_gate.GateError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    print(json.dumps(result))
    return 0


if __name__ == "__main__":
    sys.exit(main())
