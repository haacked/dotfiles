#!/usr/bin/env python3
"""Find open GitHub PRs where the user waits on someone, or someone waits on the user.

`scan` searches for open PRs that involve the signed-in `gh` user, fetches each PR's
reviews, comments, review threads, commits, and review-request events, and runs eight
checks over them. It prints one JSON document (see references/schema.md) and writes the
same document to last-scan.json and to scans/<scan_id>.json in the state directory.

`record --scan ID --sent KEY...` stores the findings a Slack DM delivered, so a later scan marks
them `notify: false` until they age another threshold or their `since` changes.

Every claim that nothing happened after a time requires that the fetched windows reach
back to that time. When a window is cut off, the check reports the PR under
`incomplete` instead of guessing.
"""

from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass
from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


SCHEMA_VERSION = 1
CHECK_IDS = range(1, 9)
DAY = timedelta(days=1)
DETAIL_BATCH = 10
FETCH_WORKERS = 4
SEARCH_CAP = 1000
EXCERPT_LIMIT = 280
STATE_RETENTION = timedelta(days=90)
SCANS_KEPT = 10
SCAN_ID = re.compile(r"\d{8}T\d{12}Z")

CHECK_NAMES = {
    1: "approved_unmerged",
    2: "review_no_response",
    3: "new_commits_no_rerequest",
    4: "unanswered_question",
    5: "stale_approval",
    6: "reply_awaiting_me",
    7: "review_requested",
    8: "my_pr_stalled",
}

WAITING_ON_ME = "waiting_on_me"
WAITING_ON_OTHERS = "waiting_on_others"

# {days} is text such as "3 days". Other fields come from the candidate.
REASONS = {
    (1, "conflicts"): "You approved it, it has merge conflicts, and nothing has moved for {days}.",
    (1, "ci_failing"): "You approved it, CI is failing, and nothing has moved for {days}.",
    (1, "needs_other_reviews"): "You approved it, it still needs other reviews, and nothing has moved for {days}.",
    (1, "ready"): "You approved it and it is still not merged after {days}.",
    (2, "no_response"): "The author has not pushed or replied for {days} since your review.",
    (3, "not_rerequested"): "New commits landed after your review, and the author has not re-requested your review. Waiting {days}.",
    (3, "rerequest_removed"): "New commits landed after your review. The author re-requested your review, but the request was removed. Waiting {days}.",
    (4, "question"): "{questions} had no reply for {days}.",
    (5, "new_commits"): "New commits landed after your approval, and it is still not merged after {days}.",
    (6, "reply"): "{other} replied to your comment {days} ago, and you have not answered.",
    (6, "mention"): "{other} mentioned you {days} ago, and you have not answered.",
    (7, "requested"): "Your review was requested {days} ago.",
    (7, "rerequested"): "Your review was re-requested {days} ago, after your earlier review.",
    (8, "changes_requested"): "{other} requested changes {days} ago, and you have not pushed or replied.",
    (8, "unaddressed_thread"): "{other} left review feedback {days} ago that you have not answered.",
    (8, "approved_conflicts"): "It was approved {days} ago, but it has merge conflicts.",
    (8, "approved_ci_failing"): "It was approved {days} ago, but CI is failing.",
    (8, "approved_ready"): "It was approved {days} ago and is not merged.",
    (8, "merge_queue"): "It was approved {days} ago and is still in the merge queue.",
}

SUGGESTED_ACTIONS = {
    (1, "conflicts"): "Ask {author} whether they plan to resolve the conflicts and merge",
    (1, "ci_failing"): "Ask {author} whether the CI failure blocks the merge",
    (1, "needs_other_reviews"): "Ask {author} whether they need help getting the other reviews",
    (1, "ready"): "Ask {author} whether anything blocks the merge",
    (2, "no_response"): "Ask {author} whether they saw your review",
    (3, "not_rerequested"): "Re-review the new commits, or ask {author} whether they want another look",
    (3, "rerequest_removed"): "Re-review the new commits",
    (4, "question"): "Ask your question again, or ask {author} who can answer it",
    (5, "new_commits"): "Re-review the new commits so your approval covers them",
    (6, "reply"): "Answer {other}'s reply",
    (6, "mention"): "Answer {other}'s comment",
    (7, "requested"): "Review the PR, or ask {author} to remove the request",
    (7, "rerequested"): "Review the new changes",
    (8, "changes_requested"): "Push the requested changes, or reply to {other}",
    (8, "unaddressed_thread"): "Reply to {other}, or resolve the thread",
    (8, "approved_conflicts"): "Resolve the conflicts and merge",
    (8, "approved_ci_failing"): "Fix CI and merge",
    (8, "approved_ready"): "Merge it",
    (8, "merge_queue"): "Check why the merge queue has not landed it",
}

# Lower ranks win when one PR has several findings. Check 2 outranks check 4, because judging can drop a check 4 finding and would then hide the PR.
CHECK_RANK = [
    (7, None),
    (6, None),
    (8, "changes_requested"),
    (8, "unaddressed_thread"),
    (8, None),
    (1, None),
    (5, None),
    (3, None),
    (2, None),
    (4, None),
]

SEARCH_QUERY = """
query($q: String!, $cursor: String) {
  search(query: $q, type: ISSUE, first: 100, after: $cursor) {
    issueCount
    pageInfo { hasNextPage endCursor }
    nodes { ... on PullRequest { id } }
  }
}
"""

DETAIL_QUERY = """
query($ids: [ID!]!) {
  nodes(ids: $ids) {
    ... on PullRequest {
      id url number title state isDraft createdAt
      repository { nameWithOwner }
      author { __typename login }
      headRefOid mergeable reviewDecision isInMergeQueue
      statusCheckRollup { state }
      reviewRequests(first: 50) { nodes { requestedReviewer { __typename ... on User { login } } } }
      reviews(last: 100) { pageInfo { hasPreviousPage } nodes { state submittedAt body author { __typename login } commit { oid } } }
      comments(last: 100) { pageInfo { hasPreviousPage } nodes { createdAt body author { __typename login } } }
      reviewThreads(first: 100) {
        pageInfo { hasNextPage }
        nodes { isResolved isOutdated
          comments(last: 50) { pageInfo { hasPreviousPage } nodes { state createdAt body author { __typename login } } } }
      }
      commits(last: 100) { pageInfo { hasPreviousPage } nodes { commit { oid committedDate parents { totalCount } } } }
      timelineItems(last: 100, itemTypes: [REVIEW_REQUESTED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT]) {
        pageInfo { hasPreviousPage }
        nodes { __typename
          ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on User { login } } }
          ... on HeadRefForcePushedEvent { createdAt } }
      }
    }
  }
}
"""


class GhError(Exception):
    pass


@dataclass
class Context:
    login: str
    now: datetime
    thresholds: dict
    enabled: set


@dataclass
class Post:
    """A comment, review, or thread comment, reduced to what the checks read."""

    login: str | None
    human: bool
    at: datetime
    body: str
    state: str | None = None
    oid: str | None = None


@dataclass
class Thread:
    resolved: bool
    outdated: bool
    truncated: bool
    posts: list


@dataclass
class PR:
    url: str
    number: int
    title: str
    repo: str
    author: str | None
    author_human: bool
    open: bool
    draft: bool
    created_at: datetime
    head: str | None
    mergeable: str | None
    review_decision: str | None
    in_queue: bool
    ci_state: str | None
    requested_users: set
    has_requests: bool
    reviews: list
    reviews_truncated: bool
    comments: list
    comments_truncated: bool
    threads: list
    threads_truncated: bool
    commits: list
    commits_truncated: bool
    requests: list
    force_pushes: list
    timeline_truncated: bool
    me: str = ""


def now():
    return datetime.now(timezone.utc)


def parse_time(value):
    if not value:
        return None
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def iso(value):
    return value.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ") if value else None


def is_human(actor):
    return bool(actor) and actor.get("__typename") == "User" and not (actor.get("login") or "").endswith("[bot]")


def _login(actor):
    return (actor or {}).get("login")


def _post(node, time_key):
    actor = node.get("author")
    return Post(
        login=_login(actor),
        human=is_human(actor),
        at=parse_time(node.get(time_key)),
        body=node.get("body") or "",
        state=node.get("state"),
        oid=((node.get("commit") or {}).get("oid")),
    )


def _nodes(connection):
    return (connection or {}).get("nodes") or []


def _user_login(actor):
    actor = actor or {}
    return actor["login"].lower() if actor.get("__typename") == "User" and actor.get("login") else None


def _truncated_before(connection):
    return bool(((connection or {}).get("pageInfo") or {}).get("hasPreviousPage"))


def normalize(raw, login):
    """Parse a detail-query PullRequest node. PENDING reviews and draft comments are
    dropped here, because only their author can see them."""
    reviews = [
        _post(n, "submittedAt")
        for n in _nodes(raw.get("reviews"))
        if n.get("state") != "PENDING" and n.get("submittedAt")
    ]
    threads = []
    for t in _nodes(raw.get("reviewThreads")):
        posts = [_post(c, "createdAt") for c in _nodes(t.get("comments")) if c.get("state") != "PENDING"]
        threads.append(Thread(bool(t.get("isResolved")), bool(t.get("isOutdated")), _truncated_before(t.get("comments")), posts))
    requested, has_requests = set(), False
    for n in _nodes(raw.get("reviewRequests")):
        has_requests = True
        if reviewer := _user_login(n.get("requestedReviewer")):
            requested.add(reviewer)
    requests, force_pushes = [], []
    for n in _nodes(raw.get("timelineItems")):
        if n.get("__typename") == "ReviewRequestedEvent":
            if requested_login := _user_login(n.get("requestedReviewer")):
                requests.append((requested_login, parse_time(n.get("createdAt"))))
        elif n.get("__typename") == "HeadRefForcePushedEvent":
            force_pushes.append(parse_time(n.get("createdAt")))
    commits = [
        {
            "oid": c["commit"]["oid"],
            "at": parse_time(c["commit"].get("committedDate")),
            "merge": ((c["commit"].get("parents") or {}).get("totalCount") or 0) > 1,
        }
        for c in _nodes(raw.get("commits"))
    ]
    author = raw.get("author")
    return PR(
        url=raw.get("url"),
        number=raw.get("number"),
        title=raw.get("title") or "",
        repo=(raw.get("repository") or {}).get("nameWithOwner"),
        author=_login(author),
        author_human=is_human(author),
        open=raw.get("state") == "OPEN",
        draft=bool(raw.get("isDraft")),
        created_at=parse_time(raw.get("createdAt")),
        head=raw.get("headRefOid"),
        mergeable=raw.get("mergeable"),
        review_decision=raw.get("reviewDecision"),
        in_queue=bool(raw.get("isInMergeQueue")),
        ci_state=(raw.get("statusCheckRollup") or {}).get("state"),
        requested_users=requested,
        has_requests=has_requests,
        reviews=reviews,
        reviews_truncated=_truncated_before(raw.get("reviews")),
        comments=[_post(n, "createdAt") for n in _nodes(raw.get("comments"))],
        comments_truncated=_truncated_before(raw.get("comments")),
        threads=threads,
        threads_truncated=bool(((raw.get("reviewThreads") or {}).get("pageInfo") or {}).get("hasNextPage")),
        commits=commits,
        commits_truncated=_truncated_before(raw.get("commits")),
        requests=requests,
        force_pushes=force_pushes,
        timeline_truncated=_truncated_before(raw.get("timelineItems")),
        me=login.lower(),
    )


_FENCE = re.compile(r"(```|~~~).*?(\1|$)", re.S)
_INLINE_CODE = re.compile(r"`[^`\n]*`")
# A URL ends before a closing parenthesis or bracket. A question mark after a Markdown link then survives.
_URL = re.compile(r"https?://[^\s)\]>]+")
# An indented line is code, unless it is a nested list item.
_INDENTED_CODE = re.compile(r"^(?: {4}|\t)(?!\s*(?:[-*+]|\d+[.)])\s)")


def strip_for_scan(body):
    text = _FENCE.sub(" ", body or "")
    text = _INLINE_CODE.sub(" ", text)
    text = "\n".join(
        line for line in text.splitlines() if not line.lstrip().startswith(">") and not _INDENTED_CODE.match(line)
    )
    text = _URL.sub(" ", text)
    return " ".join(text.split())


def _excerpt(body):
    """At most EXCERPT_LIMIT characters of the scanned text, starting early enough to
    include the first question and what follows it."""
    text = strip_for_scan(body)
    start = max(0, min(text.find("?") - EXCERPT_LIMIT // 2, len(text) - EXCERPT_LIMIT))
    return text[start:start + EXCERPT_LIMIT]


def has_question(body):
    return "?" in strip_for_scan(body)


def mentions(body, login):
    pattern = r"(?<![A-Za-z0-9_.-])@" + re.escape(login) + r"(?![A-Za-z0-9_-])"
    return re.search(pattern, strip_for_scan(body), re.I) is not None


def _is_me(post, pr):
    return _by(post, pr.me)


def _is_other_human(post, pr):
    return post.human and not _by(post, pr.me)


def _by(post, login):
    return post.human and (post.login or "").lower() == (login or "").lower()


def _thread_posts(pr):
    return [p for t in pr.threads for p in t.posts]


def _all_posts(pr):
    return pr.comments + pr.reviews + _thread_posts(pr)


def commits_since(pr, oid):
    """Whether the head holds non-merge commits that `oid` lacks, decided by oid only.
    `latest_at` estimates when they landed. Checks 3 and 5 count `days_stale` from it when it
    is later than the review."""
    if not oid:
        return None
    if oid == pr.head:
        return {"has_new": False, "latest_at": None}
    oids = [c["oid"] for c in pr.commits]
    if oid in oids:
        later = pr.commits[oids.index(oid) + 1:]
        times = [c["at"] for c in later if c["at"]]
        return {"has_new": any(not c["merge"] for c in later), "latest_at": max(times, default=None)}
    times = [t for t in pr.force_pushes if t] + [c["at"] for c in pr.commits[-1:] if c["at"]]
    return {"has_new": True, "latest_at": max(times, default=None)}


def covers_after(truncated, times, anchor):
    """A `last:` window shows everything after `anchor` when it is complete or reaches
    back to `anchor`."""
    if not truncated:
        return True
    if anchor is None:
        return False
    times = [t for t in times if t]
    return bool(times) and min(times) <= anchor


def _covered(pr, anchor):
    """Whether comments, reviews, and every thread show everything after `anchor`."""
    if pr.threads_truncated:
        return False
    windows = [(pr.comments_truncated, pr.comments), (pr.reviews_truncated, pr.reviews)]
    windows += [(t.truncated, t.posts) for t in pr.threads]
    return all(covers_after(truncated, [p.at for p in posts], anchor) for truncated, posts in windows)


def _activity_after(pr, who, after):
    return [p.at for p in _all_posts(pr) if _by(p, who) and p.at > after]


def _opinion(pr, login):
    """The user's latest APPROVED, CHANGES_REQUESTED, or DISMISSED review, and whether
    that answer is known. It is unknown when the review window is cut off and holds
    none of them."""
    opinions = [r for r in pr.reviews if _by(r, login) and r.state in ("APPROVED", "CHANGES_REQUESTED", "DISMISSED")]
    return max(opinions, key=lambda r: r.at, default=None), bool(opinions) or not pr.reviews_truncated


def _my_anchor(pr):
    mine = [r for r in pr.reviews if _is_me(r, pr) and r.state in ("COMMENTED", "CHANGES_REQUESTED", "DISMISSED")]
    return max(mine, key=lambda r: r.at, default=None)


def _old_enough(ctx, check, at):
    return at is not None and ctx.now - at >= ctx.thresholds[check] * DAY


def _my_approval(pr, ctx, check):
    """My standing approval and the commits since it. Returns (None, detail) when my
    reviews are cut off, and (None, None) when `check` cannot apply."""
    if not _waiting_on_author(pr):
        return None, None
    op, known = _opinion(pr, pr.me)
    if not known:
        return None, "cannot see your earlier reviews"
    if op is None or op.state != "APPROVED" or not _old_enough(ctx, check, op.at):
        return None, None
    delta = commits_since(pr, op.oid)
    return ((op, delta), None) if delta else (None, None)


def _my_review(pr, ctx, check):
    """My latest review that is not a standing approval, and the commits since it.
    Returns (None, detail) when my reviews are cut off, and (None, None) when `check`
    cannot apply."""
    if not _waiting_on_author(pr):
        return None, None
    op, known = _opinion(pr, pr.me)
    if not known:
        return None, "cannot see your earlier reviews"
    anchor = _my_anchor(pr)
    if anchor is None or (op and op.state == "APPROVED") or not _old_enough(ctx, check, anchor.at):
        return None, None
    delta = commits_since(pr, anchor.oid)
    return ((anchor, delta), None) if delta else (None, None)


def _merge_state(pr):
    if pr.mergeable == "CONFLICTING":
        return "conflicts"
    if pr.ci_state in ("FAILURE", "ERROR"):
        return "ci_failing"
    return None


def _waiting_on_author(pr):
    return pr.author_human and (pr.author or "").lower() != pr.me


# Each check returns (candidates, incomplete details).


def _cand(check, code, group, since, **extra):
    return {"check_id": check, "reason_code": code, "group": group, "since": since, **extra}


def check_1(pr, ctx):
    found, detail = _my_approval(pr, ctx, 1)
    if detail and not pr.in_queue:
        return [], [detail]
    if pr.in_queue or not found or found[1]["has_new"]:
        return [], []
    op = found[0]
    if not _covered(pr, op.at):
        return [], ["cannot see all activity since your approval"]
    since = max([op.at] + _activity_after(pr, pr.author, op.at))
    code = _merge_state(pr) or (
        "needs_other_reviews" if pr.review_decision in ("REVIEW_REQUIRED", "CHANGES_REQUESTED") else "ready"
    )
    return [_cand(1, code, WAITING_ON_OTHERS, since)], []


def check_2(pr, ctx):
    found, detail = _my_review(pr, ctx, 2)
    if detail:
        return [], [detail]
    if not found or found[0].state == "DISMISSED" or found[1]["has_new"]:
        return [], []
    anchor = found[0]
    if not _covered(pr, anchor.at):
        return [], ["cannot see all activity since your review"]
    if _activity_after(pr, pr.author, anchor.at):
        return [], []
    return [_cand(2, "no_response", WAITING_ON_OTHERS, anchor.at)], []


def check_3(pr, ctx):
    if pr.me in pr.requested_users:
        return [], []
    found, detail = _my_review(pr, ctx, 3)
    if detail:
        return [], [detail]
    if not found or not found[1]["has_new"]:
        return [], []
    anchor, delta = found
    covered = _covered(pr, anchor.at) and covers_after(
        pr.timeline_truncated, [t for _, t in pr.requests] + pr.force_pushes, anchor.at
    )
    if not covered:
        return [], ["cannot see all activity since your review"]
    since = max([anchor.at, delta["latest_at"] or anchor.at] + _activity_after(pr, pr.author, anchor.at))
    rerequested = any(who == pr.me and at > anchor.at for who, at in pr.requests)
    code = "rerequest_removed" if rerequested else "not_rerequested"
    return [_cand(3, code, WAITING_ON_OTHERS, since, rerequested=rerequested)], []


def check_4(pr, ctx):
    found, incomplete = [], []
    author_other = _waiting_on_author(pr)
    for thread in pr.threads:
        if thread.resolved:
            continue
        humans = [p for p in thread.posts if p.human]
        if not humans or not _is_me(humans[-1], pr) or not has_question(humans[-1].body):
            continue
        if not author_other and not any(_is_other_human(p, pr) for p in humans):
            continue
        found.append(humans[-1])
    others = [p.at for p in _all_posts(pr) if _is_other_human(p, pr)]
    if author_other or others:
        last_other = max(others, default=None)
        asked = [
            p
            for p in pr.comments + pr.reviews
            if _is_me(p, pr) and has_question(p.body) and (last_other is None or p.at > last_other)
            and _old_enough(ctx, 4, p.at)
        ]
        covered = [p for p in asked if _covered(pr, p.at)]
        if len(covered) < len(asked):
            incomplete.append("cannot see all replies to your question")
        found += covered
    found = sorted((p for p in found if _old_enough(ctx, 4, p.at)), key=lambda p: p.at)
    if not found:
        return [], incomplete
    questions = "Your question" if len(found) == 1 else f"{len(found)} unanswered questions; the oldest"
    excerpts = [_excerpt(p.body) for p in found]
    cand = _cand(
        4, "question", WAITING_ON_OTHERS, found[0].at,
        needs_judgment=True, excerpt=excerpts[0], excerpts=excerpts, questions=questions,
    )
    return [cand], incomplete


def check_5(pr, ctx):
    found, detail = _my_approval(pr, ctx, 5)
    if detail:
        return [], [detail]
    if not found or not found[1]["has_new"]:
        return [], []
    op, delta = found
    if not _covered(pr, op.at):
        return [], ["cannot see all activity since your approval"]
    since = max([op.at, delta["latest_at"] or op.at] + _activity_after(pr, pr.author, op.at))
    return [_cand(5, "new_commits", WAITING_ON_OTHERS, since)], []


def check_6(pr, ctx):
    found, incomplete = [], []
    for thread in pr.threads:
        if thread.resolved:
            continue
        humans = [p for p in thread.posts if p.human]
        mine = [p for p in humans if _is_me(p, pr)]
        if not mine or not humans or not _is_other_human(humans[-1], pr):
            continue
        replies = [p for p in humans if p.at > mine[-1].at and _is_other_human(p, pr)]
        if replies:
            found.append(("reply", replies[0]))
    my_times = [p.at for p in _all_posts(pr) if _is_me(p, pr)]
    my_latest = max(my_times, default=None)
    tagged = [p for p in _all_posts(pr) if _is_other_human(p, pr) and mentions(p.body, pr.me)]
    tagged = [p for p in tagged if my_latest is None or p.at > my_latest]
    if tagged and any(_old_enough(ctx, 6, p.at) for p in tagged):
        if _covered(pr, my_latest):
            found.append(("mention", min(tagged, key=lambda p: p.at)))
        else:
            incomplete.append("cannot see all comments since your last activity")
    if not found:
        return [], incomplete
    code, post = min(found, key=lambda item: item[1].at)
    return [_cand(6, code, WAITING_ON_ME, post.at, other=post.login)], incomplete


def check_7(pr, ctx):
    if pr.me not in pr.requested_users:
        return [], []
    times = [at for who, at in pr.requests if who == pr.me and at]
    if times:
        since = max(times)
    elif not pr.timeline_truncated:
        since = pr.created_at
    else:
        return [], ["cannot find when your review was requested"]
    if not _old_enough(ctx, 7, since):
        return [], []
    if not covers_after(pr.reviews_truncated, [r.at for r in pr.reviews], since):
        return [], ["cannot see all your reviews since the request"]
    mine = [r.at for r in pr.reviews if _is_me(r, pr)]
    if any(at > since for at in mine):
        return [], []
    rerequested = any(at < since for at in mine)
    code = "rerequested" if rerequested else "requested"
    return [_cand(7, code, WAITING_ON_ME, since, rerequested=rerequested)], []


def check_8(pr, ctx):
    if not pr.author_human or (pr.author or "").lower() != pr.me:
        return [], []
    found, incomplete = [], []
    reviewers = {(r.login or "").lower() for r in pr.reviews if _is_other_human(r, pr)}
    opinions = {who: _opinion(pr, who)[0] for who in sorted(reviewers)}
    opinions = {who: op for who, op in opinions.items() if op}
    for op in opinions.values():
        if op.state != "CHANGES_REQUESTED" or not _old_enough(ctx, 8, op.at):
            continue
        delta = commits_since(pr, op.oid)
        if delta is None or delta["has_new"]:
            continue
        if not _covered(pr, op.at):
            incomplete.append("cannot see all activity since the change request")
        elif not _activity_after(pr, pr.me, op.at):
            found.append(_cand(8, "changes_requested", WAITING_ON_ME, op.at, other=op.login))
    for thread in pr.threads:
        if thread.resolved or thread.outdated or thread.truncated:
            continue
        humans = [p for p in thread.posts if p.human]
        if not thread.posts or not _is_other_human(thread.posts[0], pr) or not _is_other_human(humans[-1], pr):
            continue
        found.append(_cand(8, "unaddressed_thread", WAITING_ON_ME, humans[-1].at, other=humans[-1].login))
    approvals = [op for op in opinions.values() if op.state == "APPROVED"]
    blocked = pr.has_requests or any(op.state == "CHANGES_REQUESTED" for op in opinions.values())
    undecided = pr.review_decision is None and not blocked
    approved = pr.review_decision == "APPROVED" or (undecided and not pr.reviews_truncated and approvals)
    if undecided and pr.reviews_truncated:
        incomplete.append("cannot see all reviews to tell whether it is approved")
    if approved:
        stamps = [op.at for op in approvals] or [r.at for r in pr.reviews if r.state == "APPROVED"]
        if stamps:
            since = max(stamps)
            if pr.in_queue:
                found.append(_cand(8, "merge_queue", WAITING_ON_OTHERS, since))
            else:
                code = {"conflicts": "approved_conflicts", "ci_failing": "approved_ci_failing"}.get(
                    _merge_state(pr), "approved_ready"
                )
                found.append(_cand(8, code, WAITING_ON_ME, since))
    return found, incomplete


CHECKS = {1: check_1, 2: check_2, 3: check_3, 4: check_4, 5: check_5, 6: check_6, 7: check_7, 8: check_8}


def _days_text(days):
    if days < 1:
        return "less than a day"
    return f"{days} day" if days == 1 else f"{days} days"


def _rank(cand):
    group = 0 if cand["group"] == WAITING_ON_ME else 1
    for index, (check, code) in enumerate(CHECK_RANK):
        if check == cand["check_id"] and code in (None, cand["reason_code"]):
            return (group, index)
    return (group, len(CHECK_RANK))


def last_activity(pr):
    times = [c["at"] for c in pr.commits] + pr.force_pushes + [p.at for p in _all_posts(pr) if p.human]
    return max([t for t in times if t], default=pr.created_at)


def evaluate(pr, ctx):
    """Run the enabled checks on one PR. Returns (finding or None, incomplete entries)."""
    if not pr.open or pr.draft:
        return None, []
    candidates, incomplete = [], {}
    for check in sorted(ctx.enabled):
        found, details = CHECKS[check](pr, ctx)
        candidates += found
        for detail in details:
            incomplete.setdefault(detail, set()).add(check)
    entries = [{"url": pr.url, "checks": sorted(checks), "detail": detail} for detail, checks in incomplete.items()]
    candidates = [c for c in candidates if _old_enough(ctx, c["check_id"], c["since"])]
    for cand in candidates:
        cand["days_stale"] = int((ctx.now - cand["since"]) / DAY)
    if not candidates:
        return None, entries
    best = min(candidates, key=lambda c: (_rank(c), -c["days_stale"], c["since"]))
    fields = {
        "author": pr.author or "the author",
        "days": _days_text(best["days_stale"]),
        "other": best.get("other") or "someone",
        "questions": best.get("questions", ""),
    }
    key = (best["check_id"], best["reason_code"])
    finding = {
        "key": f"{pr.url}#{best['check_id']}",
        "group": best["group"],
        "check_id": best["check_id"],
        "check_name": CHECK_NAMES[best["check_id"]],
        "reason_code": best["reason_code"],
        "reason": REASONS[key].format(**fields),
        "url": pr.url,
        "repo": pr.repo,
        "number": pr.number,
        "title": pr.title,
        "author": pr.author,
        "days_stale": best["days_stale"],
        "since": iso(best["since"]),
        "last_activity_at": iso(last_activity(pr)),
        "suggested_action": SUGGESTED_ACTIONS[key].format(**fields),
        "needs_judgment": bool(best.get("needs_judgment")),
        "excerpt": best.get("excerpt"),
        "excerpts": best.get("excerpts"),
        "rerequested": best.get("rerequested"),
        "other_checks": sorted({c["check_id"] for c in candidates} - {best["check_id"]}),
    }
    return finding, entries


def apply_state(findings, state, thresholds):
    """Set `notify`: false only for a finding with the same `since` as the one that was sent
    and that has not aged another threshold since."""
    items = (state or {}).get("items") or {}
    result = []
    for finding in findings:
        entry = items.get(finding["key"])
        quiet = (
            isinstance(entry, dict)
            and entry.get("since") == finding["since"]
            and isinstance(entry.get("days_stale"), int)
            and finding["days_stale"] < entry["days_stale"] + thresholds[finding["check_id"]]
        )
        result.append({**finding, "notify": not quiet})
    return result


def record(state, last_scan, sent_keys, now):
    """Return the state after a DM delivered `sent_keys`. Each entry stays for
    STATE_RETENTION after its DM, whatever the last scan reports, so a PR that a narrower
    or incomplete scan missed does not come back the next day. An entry from a newer
    scan than `last_scan` stays as it is."""
    findings = {f["key"]: f for f in last_scan.get("findings") or []}
    for key in sent_keys:
        if key not in findings:
            raise ValueError(f"{key} is not a finding in the last scan")
        if not findings[key].get("notify"):
            raise ValueError(f"{key} was not marked to notify in the last scan")
    cutoff = now - STATE_RETENTION
    items = {
        k: v
        for k, v in ((state or {}).get("items") or {}).items()
        if isinstance(v, dict) and (parse_time(v.get("notified_at")) or cutoff) > cutoff
    }
    scan_id = last_scan.get("scan_id")
    for key in sent_keys:
        newer = (items.get(key) or {}).get("scan_id")
        if scan_id and newer and newer > scan_id:
            continue
        items[key] = {
            "notified_at": iso(now),
            "scan_id": scan_id,
            "days_stale": findings[key]["days_stale"],
            "since": findings[key]["since"],
        }
    return {"version": 1, "items": items}


def sort_findings(findings):
    return sorted(findings, key=lambda f: (0 if f["group"] == WAITING_ON_ME else 1, -f["days_stale"], f["key"]))


def build_output(ctx, scope, findings, incomplete):
    return {
        "schema_version": SCHEMA_VERSION,
        "generated_at": iso(ctx.now),
        "scan_id": ctx.now.astimezone(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"),
        "login": ctx.login,
        "thresholds": {str(k): ctx.thresholds[k] for k in CHECK_IDS},
        "checks": sorted(ctx.enabled),
        "scope": scope,
        "findings": sort_findings(findings),
        "incomplete": incomplete,
    }


def _gh(args):
    result = subprocess.run(["gh", *args], capture_output=True, text=True)
    if result.returncode != 0:
        raise GhError((result.stderr or result.stdout or "gh failed").strip())
    return result.stdout


def gh_login():
    return _gh(["api", "user", "--jq", ".login"]).strip()


def gh_graphql(query, fields):
    args = ["api", "graphql", "-f", f"query={query}"]
    for name, value in fields:
        args += ["-f", f"{name}={value}"]
    data = json.loads(_gh(args))
    if data.get("errors"):
        raise GhError("; ".join(e.get("message", "GraphQL error") for e in data["errors"]))
    return data["data"]


def search_queries(login, scope, since_date):
    qualifiers = [f"user:{org}" for org in scope["orgs"]] + [f"repo:{repo}" for repo in scope["repos"]] or [""]
    base = "is:pr is:open draft:false archived:false"
    windowed = f"updated:>={since_date.isoformat()}"
    kinds = [(f"involves:{login}", windowed), (f"reviewed-by:{login}", windowed), (f"user-review-requested:{login}", "")]
    return [" ".join(part for part in (base, kind, qualifier, window) if part) for kind, window in kinds for qualifier in qualifiers]


def search_pr_ids(queries):
    ids, incomplete = [], []
    for q in queries:
        cursor = None
        while True:
            fields = [("q", q)] + ([("cursor", cursor)] if cursor else [])
            result = gh_graphql(SEARCH_QUERY, fields)["search"]
            ids += [n["id"] for n in result.get("nodes") or [] if n and n.get("id")]
            if result["pageInfo"]["hasNextPage"]:
                cursor = result["pageInfo"]["endCursor"]
                continue
            if (result.get("issueCount") or 0) > SEARCH_CAP:
                incomplete.append({"url": None, "checks": [], "detail": f"search capped at {SEARCH_CAP} results: {q}"})
            break
    return list(dict.fromkeys(ids)), incomplete


def fetch_prs(ids):
    batches = [[("ids[]", i) for i in ids[start:start + DETAIL_BATCH]] for start in range(0, len(ids), DETAIL_BATCH)]
    with ThreadPoolExecutor(max_workers=FETCH_WORKERS) as pool:
        pages = pool.map(lambda fields: gh_graphql(DETAIL_QUERY, fields)["nodes"], batches)
        return [n for page in pages for n in page if n and n.get("url")]


def state_dir():
    return Path(os.environ.get("PR_FOLLOWUPS_STATE_DIR") or Path.home() / ".local/state/pr-followups")


def load_json(path, label):
    try:
        data = json.loads(path.read_text())
    except FileNotFoundError:
        return None
    except (OSError, ValueError) as error:
        print(f"warning: ignoring unreadable {label} {path}: {error}", file=sys.stderr)
        return None
    if not isinstance(data, dict):
        print(f"warning: ignoring malformed {label} {path}", file=sys.stderr)
        return None
    return data


def load_state(path):
    data = load_json(path, "state file")
    if data is None or not isinstance(data.get("items"), dict):
        return {"version": 1, "items": {}}
    return data


def write_json(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile("w", dir=path.parent, prefix=f".{path.name}.", delete=False) as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")
        temp = handle.name
    try:
        os.replace(temp, path)
    except BaseException:
        os.unlink(temp)
        raise


def _check_list(value):
    try:
        ids = {int(part) for part in value.split(",") if part.strip()}
    except ValueError:
        raise argparse.ArgumentTypeError(f"invalid check list: {value}")
    if not ids or not ids <= set(CHECK_IDS):
        raise argparse.ArgumentTypeError(f"check IDs must be 1 to 8: {value}")
    return ids


def _threshold(value):
    check, _, days = value.partition("=")
    if check.strip() not in [str(c) for c in CHECK_IDS]:
        raise argparse.ArgumentTypeError(f"expected CHECK=DAYS with a check 1 to 8: {value}")
    return int(check), _days(days)


def _scan_id(value):
    if not SCAN_ID.fullmatch(value):
        raise argparse.ArgumentTypeError(f"expected a scan_id such as 20261119T154500000000Z: {value}")
    return value


def _days(value):
    try:
        days = int(value)
    except ValueError:
        raise argparse.ArgumentTypeError(f"expected a whole number of days: {value}")
    if days < 0:
        raise argparse.ArgumentTypeError(f"days must be at least 0: {value}")
    return days


def parse_args(argv):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = parser.add_subparsers(dest="command", required=True)
    scan = sub.add_parser("scan", help="find PRs waiting on someone and print JSON")
    scan.add_argument("--days", type=_days, default=2, help="default threshold in days for every check (default 2)")
    scan.add_argument("--threshold", type=_threshold, action="append", default=[], metavar="CHECK=DAYS")
    scan.add_argument("--checks", type=_check_list, help="comma-separated check IDs to run (default all)")
    scan.add_argument("--skip", type=_check_list, default=set(), help="comma-separated check IDs to skip")
    scan.add_argument("--org", action="append", default=[], metavar="OWNER", help="limit to an org or user (repeatable)")
    scan.add_argument("--repo", action="append", default=[], metavar="OWNER/NAME", help="limit to a repo (repeatable)")
    scan.add_argument("--lookback-days", type=_days, default=30, help="skip PRs not updated in this many days (default 30)")
    rec = sub.add_parser("record", help="store the findings a Slack DM delivered")
    rec.add_argument("--sent", action="append", required=True, metavar="KEY")
    rec.add_argument("--scan", type=_scan_id, metavar="SCAN_ID", help="the scan_id whose findings the DM sent (default: the latest scan)")
    args = parser.parse_args(argv)
    if args.command == "scan":
        args.enabled = (args.checks or set(CHECK_IDS)) - args.skip
        if not args.enabled:
            parser.error("no checks left to run")
    return args


def run_scan(args):
    current = now()
    thresholds = {check: args.days for check in CHECK_IDS}
    thresholds.update(dict(args.threshold))
    login = gh_login()
    ctx = Context(login=login, now=current, thresholds=thresholds, enabled=args.enabled)
    scope = {"orgs": args.org, "repos": args.repo, "lookback_days": args.lookback_days}
    since_date = (current - args.lookback_days * DAY).date()
    ids, incomplete = search_pr_ids(search_queries(login, scope, since_date))
    findings = []
    for raw in fetch_prs(ids):
        finding, entries = evaluate(normalize(raw, login), ctx)
        incomplete += entries
        if finding:
            findings.append(finding)
    directory = state_dir()
    findings = apply_state(findings, load_state(directory / "state.json"), thresholds)
    output = build_output(ctx, scope, findings, incomplete)
    write_json(directory / "last-scan.json", output)
    write_json(directory / "scans" / f"{output['scan_id']}.json", output)
    for old in sorted((directory / "scans").glob("*.json"))[:-SCANS_KEPT]:
        old.unlink(missing_ok=True)
    return output


def run_record(args):
    directory = state_dir()
    path = directory / "scans" / f"{args.scan}.json" if args.scan else directory / "last-scan.json"
    last_scan = load_json(path, "scan")
    if last_scan is None:
        raise ValueError(f"no scan to record from at {path}; run scan first")
    directory.mkdir(parents=True, exist_ok=True)
    with open(directory / "state.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        state = record(load_state(directory / "state.json"), last_scan, args.sent, now())
        write_json(directory / "state.json", state)
    return {"recorded": args.sent}


def main(argv=None):
    args = parse_args(sys.argv[1:] if argv is None else argv)
    try:
        output = run_scan(args) if args.command == "scan" else run_record(args)
    except (GhError, ValueError) as error:
        print(json.dumps({"error": str(error)}))
        return 1
    print(json.dumps(output, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
