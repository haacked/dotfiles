#!/usr/bin/env python3
"""Decide whether go's Merge step may merge a PR, from the PR's current state on GitHub.

The gate is read-only. It never merges, comments, or labels anything. It prints one
JSON verdict and exits 0 when the PR may merge, 3 when it may not, and 1 when the
PR's state could not be read.

In every repository, the gate refuses when:
  - the PR is not open, is a draft, has a head other than --head, or targets a
    branch other than the repository's default branch;
  - GitHub does not report it MERGEABLE after one 30-second retry of UNKNOWN;
  - a check, deduplicated the way ci-monitor's checks-rollup.jq does, is not passing
    or skipped;
  - the review decision is REVIEW_REQUIRED or CHANGES_REQUESTED, or a reviewer's
    latest decisive review requests changes;
  - a requested bot has not reviewed yet;
  - a person other than the author wrote a conversation comment or a non-empty
    COMMENTED review body, because address-pr-reviews reads neither. The refusal
    clears only when that person's latest decisive review approves the head, comes
    from an owner, member, or collaborator, and was submitted after every review
    body and conversation comment they wrote or edited. A comment without a time,
    a review that GraphQL does not list with its edit time, and a comment from a
    deleted user never clear;
  - a person other than the author commented in an unresolved review thread, or
    replied in a bot's thread that was resolved;
  - feedback arrived after --addressed-at: a review that is neither an approval nor
    stamphog's verdict, or a review comment from anyone but the author.

The verdict's address_again is true when a later address-pr-reviews pass could clear
a refusal: feedback after --addressed-at, a ReviewHog round that finished late or
not at all, or no --addressed-at.

The verdict's manual_merge is true when every reason is a person's conversation
comment or review body. Rerunning /go cannot clear those reasons. A person has to
merge the PR by hand, or each commenter has to approve the head.

PostHog repositories also need stamphog's latest review at the head to be APPROVED,
or a person's approval at the head. Unless --no-reviewhog is passed, a ReviewHog
round must have finished after the latest posthog-review label and before
--addressed-at. wait-for-pr-reviews' pending-reviews.jq decides when the round
finished.

haacked repositories also need every pending review request answered, every
requested bot to have reviewed, every requested person to have approved the head,
and an approval at the head whenever GitHub counts one. A repository that requests
and requires no reviewers passes without an approval.

In both policies, only an approval from a repository owner, member, or
collaborator counts as a person's approval.

Every other owner is refused, because go has no definition of approval there.
"""

import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import time


STAMPHOG_LOGIN = "stamphog[bot]"
SKILLS_DIR = Path(__file__).resolve().parents[2]
PENDING_REVIEWS_JQ = SKILLS_DIR / "wait-for-pr-reviews" / "scripts" / "helpers" / "pending-reviews.jq"
COPILOT_LOGINS = set(json.loads((SKILLS_DIR / "wait-for-pr-reviews" / "scripts" / "lib" / "copilot-logins.json").read_text()))
# GitHub shows a deleted account's reviews and comments as "ghost", or with no user.
DELETED_LOGINS = {"", "ghost"}
GREEN_CHECK_BUCKETS = {"pass", "skipping"}
CHECKS_ROLLUP_JQ = SKILLS_DIR / "ci-monitor" / "scripts" / "helpers" / "checks-rollup.jq"
MERGEABILITY_RETRY_SECONDS = 30
DECISIVE_REVIEW_STATES = {"APPROVED", "CHANGES_REQUESTED", "DISMISSED"}
# Any GitHub account can approve a public repository's PR, so other associations do not count.
TRUSTED_ASSOCIATIONS = {"OWNER", "MEMBER", "COLLABORATOR"}
MERGE_METHOD_ORDER = ("SQUASH", "MERGE", "REBASE")
POLICIES = {"posthog", "haacked"}
ISO_UTC = re.compile(r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$")
PR_URL = re.compile(r"^https://github\.com/([^/]+)/([^/]+)/pull/(\d+)$")

THREADS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewRequests(first: 100) {
        nodes { requestedReviewer { __typename ... on User { login } ... on Bot { login } ... on Mannequin { login } ... on Team { slug } } }
      }
      reviewThreads(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          isResolved
          comments(first: 100) { nodes { url author { login __typename } } }
        }
      }
    }
  }
}
"""


# REST reviews carry no edit time, and an edit leaves submitted_at unchanged.
REVIEW_EDITS_QUERY = """
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviews(first: 100, after: $endCursor) {
        pageInfo { hasNextPage endCursor }
        nodes { databaseId lastEditedAt }
      }
    }
  }
}
"""


class GateError(Exception):
    pass


def lower(value):
    return (value or "").lower()


def is_bot(actor):
    return actor.get("type") == "Bot" or lower(actor.get("login")) in COPILOT_LOGINS


def is_person(item, author):
    return not is_bot(item) and lower(item.get("login")) != author


def same_reviewer(a, b):
    a, b = lower(a), lower(b)
    return a == b or (a in COPILOT_LOGINS and b in COPILOT_LOGINS)


def actor(user):
    user = user or {}
    return {"login": user.get("login") or "", "type": user.get("type") or user.get("__typename") or ""}


def body_changed_at(review, edits):
    """Return when the review's body last changed, or None when GraphQL did not list the review."""
    if review.get("id") not in edits or not review.get("submitted_at"):
        return None
    return max(review["submitted_at"], edits[review["id"]] or "")


def normalize(raw):
    """Turn raw gh output into the shape decide() reads."""
    pr = raw["pr"]
    repo = raw["repo"]
    allowed = [
        method
        for method, key in (("MERGE", "mergeCommitAllowed"), ("SQUASH", "squashMergeAllowed"), ("REBASE", "rebaseMergeAllowed"))
        if repo.get(key)
    ]
    checks = [{"name": c.get("name") or "", "state": c.get("state") or "", "bucket": c.get("bucket") or ""} for c in raw["checks"]]
    # gh pr view --json reviewRequests omits Bot reviewers, so requests come from GraphQL.
    first_page = raw["threads"][0]["data"]["repository"]["pullRequest"] if raw["threads"] else {}
    requests = []
    for node in (first_page.get("reviewRequests") or {}).get("nodes") or []:
        reviewer = node.get("requestedReviewer") or {}
        requests.append({"login": reviewer.get("login") or reviewer.get("slug") or "", "type": reviewer.get("__typename") or ""})
    timeline = []
    for event in raw["timeline"]:
        name = event.get("event")
        if name == "labeled":
            timeline.append({"event": name, "label": (event.get("label") or {}).get("name") or "", "created_at": event.get("created_at")})
        elif name in ("review_requested", "review_request_removed") and event.get("requested_reviewer"):
            timeline.append({"event": name, "reviewer": actor(event["requested_reviewer"]), "created_at": event.get("created_at")})
    edits = {
        node.get("databaseId"): node.get("lastEditedAt")
        for page in raw["review_edits"]
        for node in page["data"]["repository"]["pullRequest"]["reviews"]["nodes"]
    }
    threads = []
    for page in raw["threads"]:
        for node in page["data"]["repository"]["pullRequest"]["reviewThreads"]["nodes"]:
            comments = (node.get("comments") or {}).get("nodes") or [{}]
            threads.append({
                "resolved": bool(node.get("isResolved")),
                "authors": [actor(c.get("author")) for c in comments],
                "url": comments[0].get("url") or "",
            })
    return {
        "repo": {
            "owner": (repo.get("owner") or {}).get("login") or "",
            "name": repo.get("name") or "",
            "default_branch": (repo.get("defaultBranchRef") or {}).get("name") or "",
            "default_merge_method": repo.get("viewerDefaultMergeMethod") or "",
            "allowed_merge_methods": allowed,
        },
        "pr": {
            "number": pr.get("number"),
            "url": pr.get("url") or "",
            "state": pr.get("state") or "",
            "is_draft": bool(pr.get("isDraft")),
            "head_sha": pr.get("headRefOid") or "",
            "base": pr.get("baseRefName") or "",
            "author": (pr.get("author") or {}).get("login") or "",
            "review_decision": pr.get("reviewDecision") or "",
            "mergeable": pr.get("mergeable") or "",
            "checks": checks,
            "review_requests": requests,
        },
        "reviews": [
            {
                **actor(r.get("user")),
                "state": r.get("state") or "",
                "commit_id": r.get("commit_id") or "",
                "submitted_at": r.get("submitted_at"),
                "body_changed_at": body_changed_at(r, edits),
                "body": r.get("body") or "",
                "association": r.get("author_association") or "",
            }
            for r in raw["reviews"]
        ],
        "review_comments": [{**actor(c.get("user")), "created_at": c.get("created_at")} for c in raw["review_comments"]],
        "issue_comments": [
            {**actor(c.get("user")), "body": c.get("body") or "", "created_at": c.get("created_at"), "updated_at": c.get("updated_at")}
            for c in raw["issue_comments"]
        ],
        "timeline": timeline,
        "threads": threads,
    }


def by_time(items, key):
    return sorted((item for item in items if item.get(key)), key=lambda item: item[key])


def latest_decisive_reviews(reviews, author):
    latest = {}
    for review in by_time(reviews, "submitted_at"):
        if lower(review["login"]) == author or review["state"] not in DECISIVE_REVIEW_STATES:
            continue
        latest[lower(review["login"])] = review
    return latest


def trusted_approvals_at_head(reviews, author, head_sha):
    return [
        review
        for review in latest_decisive_reviews(reviews, author).values()
        if review["state"] == "APPROVED"
        and review["commit_id"] == head_sha
        and not is_bot(review)
        and review["association"] in TRUSTED_ASSOCIATIONS
    ]


def human_approvals_at_head(reviews, author, head_sha):
    return sorted(review["login"] for review in trusted_approvals_at_head(reviews, author, head_sha))


def unread_comment_reasons(data, author, head_sha):
    """Refuse each person's review body and conversation comment that address-pr-reviews never reads.

    A person's approval of the head clears their comments only when it is later than
    every one of them, so a comment written or edited after the approval still refuses.
    """
    comments = []
    for review in data["reviews"]:
        if review["state"] == "COMMENTED" and review["body"].strip() and is_person(review, author):
            comments.append((review["login"], review.get("body_changed_at"), f"{review['login']} left a review comment that address-pr-reviews does not read"))
    for comment in data["issue_comments"]:
        if is_person(comment, author):
            times = [t for t in (comment.get("created_at"), comment.get("updated_at")) if t]
            comments.append((comment["login"], max(times) if times else None, f"{comment['login'] or 'a deleted user'} commented on the PR at {comment['created_at']}"))

    approved_at = {
        lower(review["login"]): review["submitted_at"]
        for review in trusted_approvals_at_head(data["reviews"], author, head_sha)
        if lower(review["login"]) not in DELETED_LOGINS and review.get("submitted_at")
    }
    cleared = set(approved_at)
    for login, at, _ in comments:
        if at is None or at >= approved_at.get(lower(login), ""):
            cleared.discard(lower(login))
    return [reason for login, _, reason in comments if lower(login) not in cleared]


def stamphog_approved(reviews, head_sha):
    at_head = [
        review
        for review in by_time(reviews, "submitted_at")
        if lower(review["login"]) == STAMPHOG_LOGIN and review["type"] == "Bot" and review["commit_id"] == head_sha
    ]
    return bool(at_head) and at_head[-1]["state"] == "APPROVED"


def reviewhog_round(data):
    """Return pending-reviews.jq's {requested_at, completed_at} for the latest ReviewHog round.

    The labels go in empty because ReviewHog may have removed its label already. The
    jq reads the label's history from the timeline instead.
    """
    verdict_input = {
        "labels": [],
        "timeline": [e for e in data["timeline"] if e["event"] == "labeled"],
        "reviews": [{key: r.get(key) for key in ("login", "type", "body", "submitted_at")} for r in data["reviews"]],
        "comments": [{key: c.get(key) for key in ("login", "type", "body", "created_at", "updated_at")} for c in data["issue_comments"]],
        "requested_users": [],
    }
    result = subprocess.run(["jq", "-f", str(PENDING_REVIEWS_JQ)], input=json.dumps(verdict_input), capture_output=True, text=True)
    if result.returncode != 0:
        raise GateError(f"{PENDING_REVIEWS_JQ.name} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)["reviewhog"]


def reviewhog_reasons(data, addressed_at):
    """Return (reasons, address_again_reasons) for the ReviewHog round."""
    times = reviewhog_round(data)
    requested, finished = times["requested_at"], times["completed_at"]
    if not requested:
        return ["no ReviewHog round was requested on this PR"], []
    if not finished:
        return [], [f"the ReviewHog round requested at {requested} has not finished"]
    if addressed_at and finished > addressed_at:
        return [], [f"the ReviewHog round finished at {finished}, after reviews were addressed at {addressed_at}"]
    return [], []


def requested_reviewers(timeline):
    requested = {}
    for event in by_time(timeline, "created_at"):
        if event["event"] == "review_requested":
            requested[lower(event["reviewer"]["login"])] = event["reviewer"]
        elif event["event"] == "review_request_removed":
            requested.pop(lower(event["reviewer"]["login"]), None)
    return list(requested.values())


def haacked_reasons(data, author, head_sha):
    reasons = []
    pr = data["pr"]
    pending = {lower(r["login"]) for r in pr["review_requests"]}
    approvals = human_approvals_at_head(data["reviews"], author, head_sha)
    for reviewer in requested_reviewers(data["timeline"]):
        login = reviewer["login"]
        if lower(login) in pending:
            continue
        if is_bot(reviewer):
            if not any(same_reviewer(r["login"], login) for r in data["reviews"]):
                reasons.append(f"{login} was requested but never reviewed")
        elif not any(same_reviewer(a, login) for a in approvals):
            reasons.append(f"{login} was requested and has not approved {head_sha}")
    if pr["review_decision"] == "APPROVED" and not approvals:
        reasons.append(f"GitHub counts an approval, but no reviewer approved {head_sha}")
    return reasons, approvals


def merge_method(repo):
    allowed = repo["allowed_merge_methods"]
    if repo["default_merge_method"] in allowed:
        return repo["default_merge_method"]
    return next((m for m in MERGE_METHOD_ORDER if m in allowed), None)


def decide(data, head_sha, addressed_at, reviewhog_required):
    repo, pr = data["repo"], data["pr"]
    author = lower(pr["author"])
    owner = lower(repo["owner"])
    policy = owner if owner in POLICIES else "other"
    reasons = []

    if policy == "other":
        reasons.append(f"/go merges only in PostHog and haacked repositories, not {repo['owner']}")
    if pr["state"] != "OPEN":
        reasons.append(f"the PR is {pr['state'].lower()}")
    if pr["is_draft"]:
        reasons.append("the PR is a draft")
    if pr["head_sha"] != head_sha:
        reasons.append(f"the PR head is {pr['head_sha']}, not the expected {head_sha}")
    if pr["base"] != repo["default_branch"]:
        reasons.append(f"the PR targets {pr['base'] or 'an unknown branch'}, not the default branch {repo['default_branch'] or '(unknown)'}")
    if pr["mergeable"] != "MERGEABLE":
        reasons.append(f"GitHub reports the PR as {pr['mergeable'] or 'UNKNOWN'}, not MERGEABLE")
    for check in pr["checks"]:
        if check["bucket"] not in GREEN_CHECK_BUCKETS:
            reasons.append(f"check {check['name']} is {check['state'] or 'UNKNOWN'}")
    for request in pr["review_requests"]:
        if is_bot(request) or policy == "haacked":
            reasons.append(f"the review requested from {request['login']} has not arrived")
    if pr["review_decision"] in ("CHANGES_REQUESTED", "REVIEW_REQUIRED"):
        reasons.append(f"GitHub's review decision is {pr['review_decision']}")
    for review in latest_decisive_reviews(data["reviews"], author).values():
        if review["state"] == "CHANGES_REQUESTED":
            reasons.append(f"{review['login']} requested changes")
    comment_reasons = unread_comment_reasons(data, author, head_sha)
    reasons += comment_reasons
    for thread in data["threads"]:
        people = [a["login"] or "a deleted user" for a in thread["authors"] if is_person(a, author)]
        if people and not thread["resolved"]:
            reasons.append(f"a review thread with comments from {', '.join(people)} is unresolved: {thread['url']}")
        elif people and is_bot(thread["authors"][0]):
            reasons.append(f"{', '.join(people)} replied in a bot's review thread that was resolved: {thread['url']}")

    address_again_reasons = []
    if addressed_at is None:
        address_again_reasons.append("the state file does not record when reviews were addressed")
    else:
        for review in data["reviews"]:
            if (
                review.get("submitted_at")
                and review["submitted_at"] > addressed_at
                and lower(review["login"]) not in (author, STAMPHOG_LOGIN)
                and review["state"] != "APPROVED"
            ):
                address_again_reasons.append(f"{review['login']} submitted a {review['state']} review at {review['submitted_at']}, after reviews were addressed")
        for comment in data["review_comments"]:
            if comment.get("created_at") and comment["created_at"] > addressed_at and lower(comment["login"]) != author:
                address_again_reasons.append(f"{comment['login']} left a review comment at {comment['created_at']}, after reviews were addressed")

    approved_by = []
    if policy == "posthog":
        approved_by = human_approvals_at_head(data["reviews"], author, head_sha)
        if stamphog_approved(data["reviews"], head_sha):
            approved_by.insert(0, STAMPHOG_LOGIN)
        if not approved_by:
            reasons.append(f"neither stamphog nor a human reviewer approved {head_sha}")
        if reviewhog_required:
            reviewhog_refusals, reviewhog_address_again = reviewhog_reasons(data, addressed_at)
            reasons += reviewhog_refusals
            address_again_reasons += reviewhog_address_again
    elif policy == "haacked":
        haacked_refusals, approved_by = haacked_reasons(data, author, head_sha)
        reasons += haacked_refusals

    method = merge_method(repo)
    if method is None:
        reasons.append("the repository allows no merge method")
    reasons += address_again_reasons

    return {
        "merge": not reasons,
        "address_again": bool(address_again_reasons),
        "manual_merge": bool(reasons) and len(reasons) == len(comment_reasons),
        "policy": policy,
        "pr": pr["number"],
        "url": pr["url"],
        "head_sha": head_sha,
        "method": method.lower() if method else None,
        "approved_by": approved_by,
        "reasons": reasons,
    }


def gh_json(*args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise GateError(f"gh {' '.join(args[:3])} failed: {result.stderr.strip() or result.stdout.strip()}")
    return json.loads(result.stdout)


def checks_rollup(rollup):
    result = subprocess.run(["jq", "-f", str(CHECKS_ROLLUP_JQ)], input=json.dumps(rollup), capture_output=True, text=True)
    if result.returncode != 0:
        raise GateError(f"{CHECKS_ROLLUP_JQ.name} failed: {result.stderr.strip()}")
    return json.loads(result.stdout)


def gh_pages(path):
    return [item for page in gh_json("api", "--paginate", "--slurp", path) for item in page]


def gh_graphql_pages(query, owner, name, number):
    return gh_json(
        "api", "graphql", "--paginate", "--slurp",
        "-f", f"query={query}", "-F", f"owner={owner}", "-F", f"name={name}", "-F", f"number={number}",
    )


def fetch(pr_arg):
    pr = gh_json(
        "pr", "view", *([pr_arg] if pr_arg else []),
        "--json", "number,url,state,isDraft,headRefOid,baseRefName,author,reviewDecision,mergeable,statusCheckRollup",
    )
    match = PR_URL.match(pr.get("url") or "")
    if not match:
        raise GateError(f"could not read the repository from PR URL {pr.get('url')!r}")
    owner, name, number = match.group(1), match.group(2), match.group(3)
    base = f"repos/{owner}/{name}"
    return {
        "pr": pr,
        "checks": checks_rollup(pr.get("statusCheckRollup")),
        "repo": gh_json(
            "repo", "view", f"{owner}/{name}",
            "--json", "owner,name,defaultBranchRef,viewerDefaultMergeMethod,mergeCommitAllowed,squashMergeAllowed,rebaseMergeAllowed",
        ),
        "reviews": gh_pages(f"{base}/pulls/{number}/reviews?per_page=100"),
        "review_comments": gh_pages(f"{base}/pulls/{number}/comments?per_page=100"),
        "issue_comments": gh_pages(f"{base}/issues/{number}/comments?per_page=100"),
        "timeline": gh_pages(f"{base}/issues/{number}/timeline?per_page=100"),
        "threads": gh_graphql_pages(THREADS_QUERY, owner, name, number),
        "review_edits": gh_graphql_pages(REVIEW_EDITS_QUERY, owner, name, number),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--pr", help="PR number or URL; defaults to the current branch's PR")
    parser.add_argument("--head", required=True, help="full SHA the approval must apply to")
    parser.add_argument("--addressed-at", help="UTC time (YYYY-MM-DDTHH:MM:SSZ) when the last address-pr-reviews pass started reading comments")
    parser.add_argument("--no-reviewhog", action="store_true", help="do not require a finished ReviewHog round")
    args = parser.parse_args(argv)
    if args.addressed_at is not None and not ISO_UTC.match(args.addressed_at):
        parser.error("--addressed-at must look like 2026-11-04T17:05:00Z")
    try:
        data = normalize(fetch(args.pr))
        if data["pr"]["state"] == "OPEN" and data["pr"]["mergeable"] == "UNKNOWN":
            time.sleep(MERGEABILITY_RETRY_SECONDS)
            data = normalize(fetch(args.pr))
        verdict = decide(data, args.head, args.addressed_at, not args.no_reviewhog)
    except (GateError, json.JSONDecodeError, KeyError, TypeError) as error:
        print(json.dumps({"merge": False, "error": str(error)}))
        return 1
    print(json.dumps(verdict, indent=2))
    return 0 if verdict["merge"] else 3


if __name__ == "__main__":
    sys.exit(main())
