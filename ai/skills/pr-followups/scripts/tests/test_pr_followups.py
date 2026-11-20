import contextlib
from datetime import datetime, timedelta, timezone
import importlib.util
import io
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "pr-followups.py"
SPEC = importlib.util.spec_from_file_location("pr_followups", SCRIPT)
pr_followups = importlib.util.module_from_spec(SPEC)
# dataclasses resolve string annotations through sys.modules. The module must be there before it runs.
sys.modules[SPEC.name] = pr_followups
SPEC.loader.exec_module(pr_followups)

SCHEMA_DOC = SCRIPT.parents[1] / "references" / "schema.md"

NOW = datetime(2026, 11, 19, 15, 45, tzinfo=timezone.utc)
LOGIN = "haacked"
AUTHOR = "alice"
OTHER = "bob"
REPO = "acme/widgets"
HEAD = "head0001"
TEAM = {"__typename": "Team"}
ALL = frozenset(range(1, 9))

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
REASON_CODES = {
    1: ["conflicts", "ci_failing", "needs_other_reviews", "ready"],
    2: ["no_response"],
    3: ["not_rerequested", "rerequest_removed"],
    4: ["question"],
    5: ["new_commits"],
    6: ["reply", "mention"],
    7: ["requested", "rerequested"],
    8: ["changes_requested", "unaddressed_thread", "approved_conflicts", "approved_ci_failing", "approved_ready", "merge_queue"],
}
FINDING_FIELDS = {
    "key", "group", "check_id", "check_name", "reason_code", "reason", "url", "repo", "number", "title", "author",
    "days_stale", "since", "last_activity_at", "suggested_action", "needs_judgment", "excerpt", "excerpts", "rerequested",
    "other_checks", "notify",
}
LOGIN_ARGV = ["gh", "api", "user", "--jq", ".login"]


def iso(moment):
    return moment.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def ago(days=0, hours=0):
    return iso(NOW - timedelta(days=days, hours=hours))


def parse(stamp):
    return datetime.strptime(stamp, "%Y-%m-%dT%H:%M:%SZ").replace(tzinfo=timezone.utc)


def url(number):
    return f"https://github.com/{REPO}/pull/{number}"


def actor(who):
    if who is None or isinstance(who, dict):
        return who
    return {"__typename": "User", "login": who}


def bot(login):
    return {"__typename": "Bot", "login": login}


def reviewer(who):
    return who if isinstance(who, dict) else {"__typename": "User", "login": who}


def review(who, state, when, oid=HEAD, body=""):
    return {
        "state": state,
        "submittedAt": when,
        "body": body,
        "author": actor(who),
        "commit": None if oid is None else {"oid": oid},
    }


def pending_review(body=""):
    return review(LOGIN, "PENDING", None, body=body)


def comment(who, when, body="Thanks."):
    return {"createdAt": when, "body": body, "author": actor(who)}


def tc(who, when, body="Looks fine.", state="SUBMITTED"):
    return {"state": state, "createdAt": when, "body": body, "author": actor(who)}


def thread(*comments, resolved=False, outdated=False, truncated=False):
    return {
        "isResolved": resolved,
        "isOutdated": outdated,
        "comments": {"pageInfo": {"hasPreviousPage": truncated}, "nodes": list(comments)},
    }


def commit(oid, when, parents=1):
    return {"commit": {"oid": oid, "committedDate": when, "parents": {"totalCount": parents}}}


def requested(who, when):
    return {"__typename": "ReviewRequestedEvent", "createdAt": when, "requestedReviewer": reviewer(who)}


def force_pushed(when):
    return {"__typename": "HeadRefForcePushedEvent", "createdAt": when}


def dismissed(when, who=LOGIN, previous="APPROVED"):
    return {
        "__typename": "ReviewDismissedEvent",
        "createdAt": when,
        "previousReviewState": previous,
        "review": {"author": actor(who)},
    }


TRUNCATABLE = {"reviews", "comments", "threads", "commits", "events"}


def pr(
    number=1,
    author=AUTHOR,
    reviews=(),
    comments=(),
    threads=(),
    commits=None,
    events=(),
    requests=(),
    state="OPEN",
    draft=False,
    mergeable="MERGEABLE",
    decision=None,
    ci="SUCCESS",
    merge_queue=False,
    created=None,
    title="Add widgets",
    truncated=frozenset(),
):
    """A raw PullRequest node in the exact shape DETAIL_QUERY returns."""
    unknown = set(truncated) - TRUNCATABLE
    assert not unknown, f"unknown connections: {unknown}"
    commits = list(commits) if commits is not None else [commit(HEAD, ago(10))]
    return {
        "id": f"PR_{number}",
        "url": url(number),
        "number": number,
        "title": title,
        "state": state,
        "isDraft": draft,
        "createdAt": created or ago(20),
        "repository": {"nameWithOwner": REPO},
        "author": actor(author),
        "headRefOid": commits[-1]["commit"]["oid"],
        "mergeable": mergeable,
        "reviewDecision": decision,
        "isInMergeQueue": merge_queue,
        "statusCheckRollup": None if ci is None else {"state": ci},
        "reviewRequests": {"nodes": [{"requestedReviewer": reviewer(r)} for r in requests]},
        "reviews": {"pageInfo": {"hasPreviousPage": "reviews" in truncated}, "nodes": list(reviews)},
        "comments": {"pageInfo": {"hasPreviousPage": "comments" in truncated}, "nodes": list(comments)},
        "reviewThreads": {"pageInfo": {"hasNextPage": "threads" in truncated}, "nodes": list(threads)},
        "commits": {"pageInfo": {"hasPreviousPage": "commits" in truncated}, "nodes": commits},
        "timelineItems": {"pageInfo": {"hasPreviousPage": "events" in truncated}, "nodes": list(events)},
    }


# Base fixtures. Each one fires its check at 4 days with the default threshold of 2.

def approved_pr(**kw):
    kw.setdefault("reviews", [review(LOGIN, "APPROVED", ago(4))])
    return pr(**kw)


def commented_pr(**kw):
    kw.setdefault("reviews", [review(LOGIN, "COMMENTED", ago(4))])
    return pr(**kw)


def pushed_after_review_pr(review_state="COMMENTED", **kw):
    kw.setdefault("reviews", [review(LOGIN, review_state, ago(6), oid="a1")])
    kw.setdefault("commits", [commit("a1", ago(7)), commit("b2", ago(4))])
    return pr(**kw)


def stale_approval_pr(**kw):
    return pushed_after_review_pr(review_state="APPROVED", **kw)


def question_pr(**kw):
    kw.setdefault("threads", [thread(tc(LOGIN, ago(4), "Why is this needed?"))])
    return pr(**kw)


def reply_pr(**kw):
    kw.setdefault("threads", [thread(tc(LOGIN, ago(6), "Consider caching this."), tc(OTHER, ago(4), "Caching is not needed here."))])
    return pr(**kw)


def request_pr(when=None, **kw):
    kw.setdefault("requests", [LOGIN])
    kw.setdefault("events", [requested(LOGIN, when or ago(4))])
    return pr(**kw)


def mine(**kw):
    return pr(author=LOGIN, **kw)


def changes_requested_pr(**kw):
    kw.setdefault("reviews", [review(OTHER, "CHANGES_REQUESTED", ago(4))])
    return mine(**kw)


BASE_FIXTURES = {
    1: approved_pr,
    2: commented_pr,
    3: pushed_after_review_pr,
    4: question_pr,
    5: stale_approval_pr,
    6: reply_pr,
    7: request_pr,
    8: changes_requested_pr,
}


def context(enabled=ALL, thresholds=None):
    merged = {n: 2 for n in range(1, 9)}
    merged.update(thresholds or {})
    return pr_followups.Context(login=LOGIN, now=NOW, thresholds=merged, enabled=set(enabled))


def evaluate(raw, enabled=ALL, thresholds=None):
    return pr_followups.evaluate(pr_followups.normalize(raw, LOGIN), context(enabled, thresholds))


def commits_since(raw, oid):
    return pr_followups.commits_since(pr_followups.normalize(raw, LOGIN), oid)


class CheckTestCase(unittest.TestCase):
    def assertFinding(self, result, check_id, reason_code=None, days=None, group=None):
        finding, incomplete = result
        self.assertIsNotNone(finding, f"expected check {check_id}, got no finding (incomplete={incomplete})")
        self.assertEqual(finding["check_id"], check_id, finding)
        self.assertEqual(finding["check_name"], CHECK_NAMES[check_id])
        if reason_code is not None:
            self.assertEqual(finding["reason_code"], reason_code, finding)
        if days is not None:
            self.assertEqual(finding["days_stale"], days, finding)
        if group is not None:
            self.assertEqual(finding["group"], group, finding)
        return finding

    def assertNoFinding(self, result):
        finding, _ = result
        self.assertIsNone(finding, finding)

    def assertIncomplete(self, result, check_id):
        finding, incomplete = result
        self.assertIsNone(finding, finding)
        for entry in incomplete:
            self.assertEqual(set(entry), {"url", "checks", "detail"})
        self.assertTrue(any(check_id in entry["checks"] for entry in incomplete), f"no incomplete entry for check {check_id}: {incomplete}")


class HumanTest(unittest.TestCase):
    def test_bot_with_bare_login_is_not_human(self):
        self.assertFalse(pr_followups.is_human({"__typename": "Bot", "login": "stamphog"}))

    def test_user_login_ending_in_bot_suffix_is_not_human(self):
        self.assertFalse(pr_followups.is_human({"__typename": "User", "login": "foo[bot]"}))

    def test_null_author_is_not_human(self):
        self.assertFalse(pr_followups.is_human(None))

    def test_mannequin_is_not_human(self):
        self.assertFalse(pr_followups.is_human({"__typename": "Mannequin", "login": "olduser"}))

    def test_ordinary_user_is_human(self):
        self.assertTrue(pr_followups.is_human({"__typename": "User", "login": "alice"}))

    def test_every_author_selection_in_the_queries_requests_typename(self):
        for name in ("SEARCH_QUERY", "DETAIL_QUERY"):
            query = getattr(pr_followups, name)
            for match in re.finditer(r"\bauthor\s*\{", query):
                with self.subTest(query=name, offset=match.start()):
                    self.assertRegex(query[match.end():], r"^\s*__typename\b")

    def test_detail_query_has_author_selections(self):
        self.assertRegex(pr_followups.DETAIL_QUERY, r"\bauthor\s*\{")

    def test_detail_query_does_not_use_latest_opinionated_reviews(self):
        self.assertNotIn("latestOpinionatedReviews", pr_followups.DETAIL_QUERY)

    def test_user_login_with_bot_suffix_replying_in_thread_gives_no_check_6(self):
        raw = pr(threads=[thread(tc(LOGIN, ago(6), "Consider caching this."), tc("renovate[bot]", ago(4), "Updated."))])

        self.assertIsNone(evaluate(raw, enabled={6})[0])

    def test_me_matches_login_case_insensitively(self):
        raw = approved_pr(reviews=[review("HAACKED", "APPROVED", ago(4))])

        finding, _ = evaluate(raw, enabled={1})

        self.assertEqual(finding["check_id"], 1)


class TextHelpersTest(unittest.TestCase):
    def test_strip_for_scan_removes_code_quotes_and_urls(self):
        body = "Hi `code?` there\n> quoted?\nsee https://example.com/a?b=1\n```\nfenced?\n```\nend"

        self.assertEqual(pr_followups.strip_for_scan(body).strip(), "Hi there see end")

    def test_has_question(self):
        cases = [
            ("Why is this needed?", True),
            ("No question here.", False),
            ("```\nwhy?\n```\nLooks fine.", False),
            ("Use `value?.name` here.", False),
            ("> Should this be async?\nIt is fine as is.", False),
            ("Details at https://example.com/search?q=1 for reference.", False),
        ]
        for body, expected in cases:
            with self.subTest(body=body):
                self.assertIs(pr_followups.has_question(body), expected)

    def test_mentions(self):
        cases = [
            ("@haacked can you look", True),
            ("@Haacked can you look", True),
            ("thanks @haacked, merged", True),
            ("(@haacked)", True),
            ("@haacked-bot ran", False),
            ("@haacked_two ran", False),
            ("mail email@haacked.com", False),
            ("> @haacked said this\nI agree.", False),
            ("Run `@haacked` literally.", False),
        ]
        for body, expected in cases:
            with self.subTest(body=body):
                self.assertIs(pr_followups.mentions(body, LOGIN), expected)

    def test_now_is_timezone_aware_utc(self):
        self.assertEqual(pr_followups.now().utcoffset(), timedelta(0))

    def test_every_check_and_reason_code_has_a_suggested_action(self):
        expected = {(check, code) for check, codes in REASON_CODES.items() for code in codes}

        self.assertEqual(set(pr_followups.SUGGESTED_ACTIONS), expected)

    def test_every_reason_code_has_a_reason_text(self):
        self.assertEqual(set(pr_followups.REASONS), set(pr_followups.SUGGESTED_ACTIONS))

    def test_suggested_action_templates_are_non_empty_strings(self):
        for pair, template in pr_followups.SUGGESTED_ACTIONS.items():
            with self.subTest(pair=pair):
                self.assertIsInstance(template, str)
                self.assertTrue(template.strip())


class CommitsSinceTest(unittest.TestCase):
    def test_oid_equal_to_head_has_no_new_commits(self):
        raw = pr(commits=[commit("a1", ago(7)), commit(HEAD, ago(5))])

        self.assertFalse(commits_since(raw, HEAD)["has_new"])

    def test_linear_new_commit_is_new(self):
        raw = pr(commits=[commit("a1", ago(7)), commit("b2", ago(4))])

        result = commits_since(raw, "a1")

        self.assertTrue(result["has_new"])
        self.assertEqual(result["latest_at"], parse(ago(4)))

    def test_merge_only_commits_after_oid_are_not_new(self):
        raw = pr(commits=[commit("a1", ago(7)), commit("m1", ago(4), parents=2), commit("m2", ago(3), parents=2)])

        self.assertFalse(commits_since(raw, "a1")["has_new"])

    def test_non_merge_commit_among_merges_is_new(self):
        raw = pr(commits=[commit("a1", ago(7)), commit("m1", ago(5), parents=2), commit("b2", ago(4))])

        self.assertTrue(commits_since(raw, "a1")["has_new"])

    def test_force_pushed_away_oid_is_new_with_latest_at_from_force_push(self):
        raw = pr(commits=[commit("c3", ago(9))], events=[force_pushed(ago(4))])

        result = commits_since(raw, "gone")

        self.assertTrue(result["has_new"])
        self.assertEqual(result["latest_at"], parse(ago(4)))

    def test_oid_older_than_commit_window_is_new_with_latest_at_from_head(self):
        raw = pr(commits=[commit("n1", ago(5)), commit("n2", ago(4))], truncated={"commits"})

        result = commits_since(raw, "old")

        self.assertTrue(result["has_new"])
        self.assertEqual(result["latest_at"], parse(ago(4)))

    def test_null_oid_gives_none(self):
        self.assertIsNone(commits_since(pr(), None))

    def test_new_commit_with_committed_date_before_the_review_is_still_new(self):
        raw = pr(commits=[commit("a1", ago(9)), commit("b2", ago(8))])

        self.assertTrue(commits_since(raw, "a1")["has_new"])


class CommitsSinceParityTest(CheckTestCase):
    """Checks 1, 2, 3, and 5 must agree with commits_since on every commit shape."""

    SHAPES = {
        "oid_is_head": (False, "r1", [commit("r1", ago(6))], (), ()),
        "linear_new_commit": (True, "r1", [commit("r1", ago(6)), commit("n1", ago(4))], (), ()),
        "merge_only": (False, "r1", [commit("r1", ago(6)), commit("m1", ago(4), parents=2)], (), ()),
        "force_pushed_away": (True, "gone", [commit("n1", ago(9))], [force_pushed(ago(4))], ()),
        "older_than_window": (True, "old", [commit("n1", ago(4))], (), {"commits"}),
        "null_oid": (None, None, [commit("r1", ago(6))], (), ()),
    }

    def run_shape(self, state, enabled, oid, commits, events, truncated):
        raw = pr(reviews=[review(LOGIN, state, ago(5), oid=oid)], commits=commits, events=events, truncated=truncated)
        return evaluate(raw, enabled=enabled)

    def test_check_2_and_check_3_split_on_new_commits(self):
        for name, (has_new, oid, commits, events, truncated) in self.SHAPES.items():
            with self.subTest(shape=name):
                finding, _ = self.run_shape("COMMENTED", {2, 3}, oid, commits, events, truncated)
                if has_new is None:
                    self.assertIsNone(finding)
                else:
                    self.assertEqual(finding["check_id"], 3 if has_new else 2)
                    self.assertEqual(finding["other_checks"], [])

    def test_check_1_and_check_5_split_on_new_commits(self):
        for name, (has_new, oid, commits, events, truncated) in self.SHAPES.items():
            with self.subTest(shape=name):
                finding, _ = self.run_shape("APPROVED", {1, 5}, oid, commits, events, truncated)
                if has_new is None:
                    self.assertIsNone(finding)
                else:
                    self.assertEqual(finding["check_id"], 5 if has_new else 1)
                    self.assertEqual(finding["other_checks"], [])


class CoversAfterTest(CheckTestCase):
    def test_complete_connections_allow_a_finding(self):
        self.assertFinding(evaluate(approved_pr(), enabled={1}), 1)

    def test_truncated_window_with_anchor_inside_allows_a_finding(self):
        raw = approved_pr(comments=[comment(OTHER, ago(5)), comment(OTHER, ago(2))], truncated={"comments"})

        self.assertFinding(evaluate(raw, enabled={1}), 1, days=4)

    def test_truncated_window_whose_oldest_item_is_the_anchor_allows_a_finding(self):
        raw = approved_pr(truncated={"reviews"})

        self.assertFinding(evaluate(raw, enabled={1}), 1, days=4)

    def test_truncated_window_with_anchor_older_than_window_gives_incomplete(self):
        raw = approved_pr(comments=[comment(OTHER, ago(2))], truncated={"comments"})

        self.assertIncomplete(evaluate(raw, enabled={1}), 1)

    def test_review_threads_has_next_page_gives_check_2_incomplete(self):
        raw = commented_pr(truncated={"threads"})

        self.assertIncomplete(evaluate(raw, enabled={2}), 2)

    def test_incomplete_entry_names_the_pr_url(self):
        raw = approved_pr(number=7, comments=[comment(OTHER, ago(2))], truncated={"comments"})

        _, incomplete = evaluate(raw, enabled={1})

        self.assertEqual({entry["url"] for entry in incomplete}, {url(7)})


class Check1ApprovedUnmergedTest(CheckTestCase):
    def test_approved_with_no_new_commits_is_ready(self):
        finding = self.assertFinding(evaluate(approved_pr(), enabled={1}), 1, "ready", days=4, group="waiting_on_others")

        self.assertEqual(finding["since"], ago(4))

    def test_conflicting_gives_conflicts(self):
        self.assertFinding(evaluate(approved_pr(mergeable="CONFLICTING"), enabled={1}), 1, "conflicts")

    def test_unknown_mergeable_gives_ready_not_conflicts(self):
        self.assertFinding(evaluate(approved_pr(mergeable="UNKNOWN"), enabled={1}), 1, "ready")

    def test_ci_rollup_states(self):
        cases = {"FAILURE": "ci_failing", "ERROR": "ci_failing", "PENDING": "ready", "SUCCESS": "ready", None: "ready"}
        for ci, expected in cases.items():
            with self.subTest(ci=ci):
                self.assertFinding(evaluate(approved_pr(ci=ci), enabled={1}), 1, expected)

    def test_conflicts_take_precedence_over_failing_ci(self):
        raw = approved_pr(mergeable="CONFLICTING", ci="FAILURE")

        self.assertFinding(evaluate(raw, enabled={1}), 1, "conflicts")

    def test_review_decisions_needing_other_reviews(self):
        for decision in ("REVIEW_REQUIRED", "CHANGES_REQUESTED"):
            with self.subTest(decision=decision):
                self.assertFinding(evaluate(approved_pr(decision=decision), enabled={1}), 1, "needs_other_reviews")

    def test_draft_gives_nothing(self):
        self.assertNoFinding(evaluate(approved_pr(draft=True)))

    def test_bot_author_gives_nothing(self):
        self.assertNoFinding(evaluate(approved_pr(author=bot("dependabot")), enabled={1}))

    def test_ghost_author_gives_nothing(self):
        self.assertNoFinding(evaluate(approved_pr(author=None), enabled={1}))

    def test_my_own_pr_gives_no_check_1(self):
        self.assertNoFinding(evaluate(approved_pr(author=LOGIN), enabled={1}))

    def test_in_merge_queue_gives_nothing(self):
        self.assertNoFinding(evaluate(approved_pr(merge_queue=True), enabled={1}))

    def test_author_activity_after_approval_resets_since(self):
        activities = {
            "issue_comment": {"comments": [comment(AUTHOR, ago(4), "Merging after lunch.")]},
            "review": {"reviews": [review(LOGIN, "APPROVED", ago(6)), review(AUTHOR, "COMMENTED", ago(4))]},
            "thread_comment": {"threads": [thread(tc(AUTHOR, ago(4), "Merging after lunch."))]},
        }
        for name, extra in activities.items():
            with self.subTest(activity=name):
                kw = {"reviews": [review(LOGIN, "APPROVED", ago(6))], **extra}
                finding = self.assertFinding(evaluate(approved_pr(**kw), enabled={1}), 1, days=4)
                self.assertEqual(finding["since"], ago(4))

    def test_non_author_activity_does_not_reset_since(self):
        raw = approved_pr(comments=[comment(OTHER, ago(2), "Any update?")])

        self.assertFinding(evaluate(raw, enabled={1}), 1, days=4)

    def test_truncated_comments_window_starting_after_approval_gives_incomplete(self):
        raw = approved_pr(comments=[comment(OTHER, ago(2))], truncated={"comments"})

        self.assertIncomplete(evaluate(raw, enabled={1}), 1)

    def test_review_threads_has_next_page_gives_incomplete(self):
        self.assertIncomplete(evaluate(approved_pr(truncated={"threads"}), enabled={1}), 1)

    def test_below_threshold_gives_nothing(self):
        raw = approved_pr(reviews=[review(LOGIN, "APPROVED", ago(1))])

        self.assertNoFinding(evaluate(raw, enabled={1}))

    def test_47_hours_with_2_day_threshold_gives_nothing(self):
        raw = approved_pr(reviews=[review(LOGIN, "APPROVED", ago(hours=47))])

        self.assertNoFinding(evaluate(raw, enabled={1}))

    def test_exactly_48_hours_with_2_day_threshold_fires(self):
        raw = approved_pr(reviews=[review(LOGIN, "APPROVED", ago(hours=48))])

        self.assertFinding(evaluate(raw, enabled={1}), 1, days=2)

    def test_days_stale_is_floor_of_elapsed_days(self):
        raw = approved_pr(reviews=[review(LOGIN, "APPROVED", ago(days=4, hours=23))])

        self.assertFinding(evaluate(raw, enabled={1}), 1, days=4)

    def test_null_review_commit_gives_nothing(self):
        raw = approved_pr(reviews=[review(LOGIN, "APPROVED", ago(4), oid=None)])

        self.assertNoFinding(evaluate(raw, enabled={1}))


class LatestOpinionTest(CheckTestCase):
    def test_dismissed_approval_gives_no_check_1(self):
        raw = pr(reviews=[review(LOGIN, "DISMISSED", ago(4))], events=[dismissed(ago(3))])

        self.assertNoFinding(evaluate(raw, enabled={1, 5}))

    def test_dismissed_approval_with_new_commits_gives_no_check_5(self):
        raw = pushed_after_review_pr(review_state="DISMISSED", events=[dismissed(ago(5))])

        self.assertNoFinding(evaluate(raw, enabled={5}))

    def test_approval_followed_by_dismissed_state_gives_no_standing_opinion(self):
        cases = {
            "no_new_commits": pr(reviews=[review(LOGIN, "APPROVED", ago(6)), review(LOGIN, "DISMISSED", ago(4))]),
            "new_commits": pushed_after_review_pr(reviews=[review(LOGIN, "APPROVED", ago(6), oid="a1"), review(LOGIN, "DISMISSED", ago(5), oid="a1")]),
        }
        for name, raw in cases.items():
            with self.subTest(case=name):
                self.assertNoFinding(evaluate(raw, enabled={1, 5}))

    def test_approval_followed_by_my_changes_request_gives_no_check_1(self):
        raw = pr(reviews=[review(LOGIN, "APPROVED", ago(6)), review(LOGIN, "CHANGES_REQUESTED", ago(4))])

        finding, _ = evaluate(raw, enabled={1})

        self.assertIsNone(finding)

    def test_later_approval_suppresses_check_2_from_earlier_comment(self):
        raw = pr(reviews=[review(LOGIN, "COMMENTED", ago(6)), review(LOGIN, "APPROVED", ago(4))])

        self.assertNoFinding(evaluate(raw, enabled={2}))

    def test_truncated_reviews_without_my_opinion_gives_check_2_incomplete(self):
        raw = commented_pr(truncated={"reviews"})

        self.assertIncomplete(evaluate(raw, enabled={2}), 2)

    def test_truncated_reviews_without_my_opinion_gives_check_3_incomplete(self):
        raw = pushed_after_review_pr(truncated={"reviews"})

        self.assertIncomplete(evaluate(raw, enabled={3}), 3)


class PendingItemsTest(CheckTestCase):
    def test_pending_thread_comment_with_question_gives_no_check_4(self):
        cases = {"SUBMITTED": True, "PENDING": False}
        for state, fires in cases.items():
            with self.subTest(state=state):
                raw = pr(threads=[thread(tc(AUTHOR, ago(6), "Added caching."), tc(LOGIN, ago(4), "Why is this needed?", state=state))])
                finding, _ = evaluate(raw, enabled={4})
                self.assertEqual(finding is not None, fires, finding)

    def test_pending_review_with_null_submitted_at_is_ignored(self):
        raw = approved_pr(reviews=[review(LOGIN, "APPROVED", ago(4)), pending_review(body="Why is this needed?")])

        self.assertFinding(evaluate(raw), 1, days=4)

    def test_pending_review_body_is_not_a_check_4_question(self):
        raw = pr(reviews=[pending_review(body="Why is this needed?")])

        self.assertNoFinding(evaluate(raw, enabled={4}))

    def test_pending_comment_does_not_make_thread_count_for_check_6(self):
        cases = {"SUBMITTED": True, "PENDING": False}
        for state, fires in cases.items():
            with self.subTest(state=state):
                raw = pr(threads=[thread(tc(LOGIN, ago(6), "Consider caching this.", state=state), tc(OTHER, ago(4), "Not needed."))])
                finding, _ = evaluate(raw, enabled={6})
                self.assertEqual(finding is not None, fires, finding)

    def test_pending_comment_is_not_my_latest_activity_for_mentions(self):
        raw = pr(
            comments=[comment(OTHER, ago(5), "@haacked what do you think")],
            threads=[thread(tc(LOGIN, ago(4), "Draft reply", state="PENDING"))],
        )

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention", days=5)

    def test_pending_review_is_never_the_anchor_for_checks_2_or_3(self):
        cases = {
            "no_new_commits": pr(reviews=[pending_review(body="Please rename.")]),
            "new_commits": pr(reviews=[pending_review(body="Please rename.")], commits=[commit("a1", ago(7)), commit("b2", ago(4))]),
        }
        for name, raw in cases.items():
            with self.subTest(case=name):
                self.assertNoFinding(evaluate(raw, enabled={2, 3}))

    def test_pending_thread_comment_after_changes_request_still_leaves_check_8(self):
        raw = changes_requested_pr(threads=[thread(tc(OTHER, ago(4), "Rename this."), tc(LOGIN, ago(3), "Done", state="PENDING"))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "changes_requested")


class Check2ReviewNoResponseTest(CheckTestCase):
    def test_commented_review_with_silent_author_fires(self):
        self.assertFinding(evaluate(commented_pr(), enabled={2}), 2, "no_response", days=4, group="waiting_on_others")

    def test_changes_requested_review_with_silent_author_fires(self):
        raw = pr(reviews=[review(LOGIN, "CHANGES_REQUESTED", ago(4))])

        self.assertFinding(evaluate(raw, enabled={2}), 2, "no_response", days=4)

    def test_author_thread_reply_after_review_gives_nothing(self):
        raw = commented_pr(threads=[thread(tc(LOGIN, ago(4), "Rename this."), tc(AUTHOR, ago(3), "Done."))])

        self.assertNoFinding(evaluate(raw, enabled={2}))

    def test_author_issue_comment_after_review_gives_nothing(self):
        raw = commented_pr(comments=[comment(AUTHOR, ago(3), "Working on it.")])

        self.assertNoFinding(evaluate(raw, enabled={2}))

    def test_author_review_after_review_gives_nothing(self):
        raw = pr(reviews=[review(LOGIN, "COMMENTED", ago(4)), review(AUTHOR, "COMMENTED", ago(3))])

        self.assertNoFinding(evaluate(raw, enabled={2}))

    def test_new_non_merge_commit_gives_check_3_not_check_2(self):
        raw = pushed_after_review_pr()

        self.assertNoFinding(evaluate(raw, enabled={2}))
        self.assertFinding(evaluate(raw, enabled={2, 3}), 3)

    def test_merge_only_commit_still_fires(self):
        raw = pr(reviews=[review(LOGIN, "COMMENTED", ago(4), oid="a1")], commits=[commit("a1", ago(7)), commit("m1", ago(3), parents=2)])

        self.assertFinding(evaluate(raw, enabled={2}), 2, days=4)

    def test_dismissed_anchor_gives_nothing(self):
        raw = pr(reviews=[review(LOGIN, "DISMISSED", ago(4))], events=[dismissed(ago(3))])

        self.assertNoFinding(evaluate(raw, enabled={2}))

    def test_bot_reply_after_review_does_not_count_as_response(self):
        raw = commented_pr(
            comments=[comment(bot("stamphog"), ago(3), "Approved by stamphog.")],
            threads=[thread(tc(LOGIN, ago(4), "Rename this."), tc(bot("copilot"), ago(3), "Suggested fix."))],
        )

        self.assertFinding(evaluate(raw, enabled={2}), 2, days=4)

    def test_ghost_reply_after_review_does_not_count_as_response(self):
        raw = commented_pr(comments=[comment(None, ago(3), "Deleted account.")])

        self.assertFinding(evaluate(raw, enabled={2}), 2, days=4)

    def test_null_review_commit_gives_nothing(self):
        raw = pr(reviews=[review(LOGIN, "COMMENTED", ago(4), oid=None)])

        self.assertNoFinding(evaluate(raw, enabled={2}))

    def test_review_threads_has_next_page_gives_incomplete(self):
        self.assertIncomplete(evaluate(commented_pr(truncated={"threads"}), enabled={2}), 2)

    def test_truncated_comments_starting_after_review_gives_incomplete(self):
        raw = commented_pr(comments=[comment(OTHER, ago(2))], truncated={"comments"})

        self.assertIncomplete(evaluate(raw, enabled={2}), 2)

    def test_truncated_thread_window_starting_after_review_gives_incomplete(self):
        raw = commented_pr(threads=[thread(tc(OTHER, ago(2), "Same question."), truncated=True)])

        self.assertIncomplete(evaluate(raw, enabled={2}), 2)

    def test_truncated_thread_window_covering_review_still_fires(self):
        raw = commented_pr(threads=[thread(tc(OTHER, ago(5), "Earlier note."), tc(OTHER, ago(2), "Same question."), truncated=True)])

        self.assertFinding(evaluate(raw, enabled={2}), 2, days=4)


class Check3NewCommitsNoRerequestTest(CheckTestCase):
    def test_new_commits_without_request_fires_with_rerequested_false(self):
        finding = self.assertFinding(evaluate(pushed_after_review_pr(), enabled={3}), 3, "not_rerequested", days=4, group="waiting_on_others")

        self.assertIs(finding["rerequested"], False)
        self.assertRegex(finding["reason"], r"has not re-requested your review")

    def test_removed_rerequest_fires_with_rerequested_true(self):
        raw = pushed_after_review_pr(events=[requested(LOGIN, ago(5))])

        finding = self.assertFinding(evaluate(raw, enabled={3}), 3, "rerequest_removed")

        self.assertIs(finding["rerequested"], True)
        self.assertRegex(finding["reason"], r"re-requested your review,? but the request was removed")

    def test_request_before_my_review_does_not_count_as_rerequest(self):
        raw = pushed_after_review_pr(events=[requested(LOGIN, ago(8))])

        finding = self.assertFinding(evaluate(raw, enabled={3}), 3, "not_rerequested")

        self.assertIs(finding["rerequested"], False)

    def test_open_rerequest_gives_no_check_3(self):
        raw = pushed_after_review_pr(requests=[LOGIN], events=[requested(LOGIN, ago(3))])

        self.assertNoFinding(evaluate(raw, enabled={3}))

    def test_open_rerequest_gives_check_7_with_rerequest_reason(self):
        raw = pushed_after_review_pr(requests=[LOGIN], events=[requested(LOGIN, ago(3))])

        finding = self.assertFinding(evaluate(raw), 7, "rerequested")

        self.assertNotIn(3, finding["other_checks"])
        self.assertIn("re-requested", finding["reason"])

    def test_dismissed_approval_with_new_commits_fires(self):
        raw = pushed_after_review_pr(review_state="DISMISSED", events=[dismissed(ago(5))])

        self.assertFinding(evaluate(raw, enabled={3}), 3, days=4)

    def test_changes_requested_anchor_with_new_commits_fires(self):
        self.assertFinding(evaluate(pushed_after_review_pr(review_state="CHANGES_REQUESTED"), enabled={3}), 3, days=4)

    def test_force_push_counts_as_new_commits(self):
        raw = pr(
            reviews=[review(LOGIN, "COMMENTED", ago(8), oid="gone")],
            commits=[commit("c3", ago(9))],
            events=[force_pushed(ago(4))],
        )

        self.assertFinding(evaluate(raw, enabled={3}), 3, days=4)

    def test_author_activity_after_push_moves_since(self):
        raw = pushed_after_review_pr(comments=[comment(AUTHOR, ago(3), "Pushed a fix.")])

        self.assertFinding(evaluate(raw, enabled={3}), 3, days=3)

    def test_null_review_commit_gives_nothing(self):
        raw = pushed_after_review_pr(reviews=[review(LOGIN, "COMMENTED", ago(6), oid=None)])

        self.assertNoFinding(evaluate(raw, enabled={3}))

    def test_review_threads_has_next_page_gives_incomplete(self):
        self.assertIncomplete(evaluate(pushed_after_review_pr(truncated={"threads"}), enabled={3}), 3)

    def test_truncated_timeline_starting_after_review_gives_incomplete(self):
        raw = pushed_after_review_pr(events=[requested(OTHER, ago(5))], truncated={"events"})

        self.assertIncomplete(evaluate(raw, enabled={3}), 3)

    def test_my_own_pr_gives_no_check_3(self):
        self.assertNoFinding(evaluate(pushed_after_review_pr(author=LOGIN), enabled={3}))


class Check4UnansweredQuestionTest(CheckTestCase):
    def test_every_open_question_reaches_the_judge_oldest_first(self):
        raw = pr(threads=[
            thread(tc(LOGIN, ago(4), "Which timeout should the client use?")),
            thread(tc(LOGIN, ago(5), "Why complicate this? We should keep it simple.")),
        ])

        finding = self.assertFinding(evaluate(raw, enabled={4}), 4, days=5)

        self.assertEqual(finding["excerpts"], [
            "Why complicate this? We should keep it simple.",
            "Which timeout should the client use?",
        ])
        self.assertEqual(finding["excerpt"], finding["excerpts"][0])

    def test_uncovered_older_question_does_not_hide_a_covered_newer_one(self):
        raw = pr(
            comments=[comment(LOGIN, ago(10), "Why this limit?"), comment(LOGIN, ago(4), "Which timeout applies?")],
            reviews=[review(bot("copilot"), "COMMENTED", ago(5))],
            truncated={"reviews"},
        )

        finding, incomplete = evaluate(raw, enabled={4})

        self.assertEqual(finding["excerpts"], ["Which timeout applies?"])
        self.assertTrue(any(4 in entry["checks"] for entry in incomplete))

    def test_later_statement_of_mine_does_not_hide_my_open_question(self):
        raw = pr(comments=[
            comment(LOGIN, ago(5), "Can you explain the retry limit?"),
            comment(LOGIN, ago(4), "I also checked the CI logs."),
        ])

        finding = self.assertFinding(evaluate(raw, enabled={4}), 4, days=5)

        self.assertEqual(finding["excerpts"], ["Can you explain the retry limit?"])

    def test_question_answered_by_someone_else_stays_closed(self):
        raw = pr(comments=[
            comment(LOGIN, ago(6), "Can you explain the retry limit?"),
            comment(OTHER, ago(5), "It matches the server."),
            comment(LOGIN, ago(4), "Which server?"),
        ])

        finding = self.assertFinding(evaluate(raw, enabled={4}), 4, days=4)

        self.assertEqual(finding["excerpts"], ["Which server?"])

    def test_bot_comment_last_in_thread_does_not_answer_the_question(self):
        raw = question_pr(threads=[thread(tc(LOGIN, ago(4), "Why is this needed?"), tc(bot("copilot"), ago(3), "Suggested fix."))])

        self.assertFinding(evaluate(raw, enabled={4}), 4, days=4)

    def test_inline_thread_where_i_asked_last_fires_with_judgment(self):
        finding = self.assertFinding(evaluate(question_pr(), enabled={4}), 4, "question", days=4, group="waiting_on_others")

        self.assertIs(finding["needs_judgment"], True)
        self.assertEqual(finding["excerpt"], "Why is this needed?")

    def test_reply_after_my_question_gives_nothing(self):
        raw = question_pr(threads=[thread(tc(LOGIN, ago(5), "Why is this needed?"), tc(AUTHOR, ago(4), "For caching."))])

        self.assertNoFinding(evaluate(raw, enabled={4}))

    def test_resolved_thread_gives_nothing(self):
        raw = question_pr(threads=[thread(tc(LOGIN, ago(4), "Why is this needed?"), resolved=True)])

        self.assertNoFinding(evaluate(raw, enabled={4}))

    def test_question_mark_outside_prose_gives_nothing(self):
        bodies = {
            "fenced": "```python\nx = y if z else w  # why?\n```\nLooks fine.",
            "inline_code": "Use `value?.name` here.",
            "quote": "> Should this be async?\nI think it is fine as is.",
            "url": "Details at https://example.com/search?q=1 for reference.",
        }
        for name, body in bodies.items():
            with self.subTest(body=name):
                raw = question_pr(threads=[thread(tc(LOGIN, ago(4), body))])
                self.assertNoFinding(evaluate(raw, enabled={4}))

    def test_comment_without_question_mark_gives_nothing(self):
        raw = question_pr(threads=[thread(tc(LOGIN, ago(4), "Please explain why this is needed."))])

        self.assertNoFinding(evaluate(raw, enabled={4}))

    def test_top_level_question_with_later_human_reply_gives_nothing(self):
        replies = {
            "issue_comment": {"comments": [comment(LOGIN, ago(6), "Can you add a test?"), comment(OTHER, ago(5), "Sure.")]},
            "review": {"comments": [comment(LOGIN, ago(6), "Can you add a test?")], "reviews": [review(OTHER, "COMMENTED", ago(5))]},
            "thread_comment": {"comments": [comment(LOGIN, ago(6), "Can you add a test?")], "threads": [thread(tc(AUTHOR, ago(5), "Added one."))]},
        }
        for name, kw in replies.items():
            with self.subTest(reply=name):
                self.assertNoFinding(evaluate(pr(**kw), enabled={4}))

    def test_top_level_question_with_only_later_bot_comment_fires(self):
        raw = pr(comments=[comment(LOGIN, ago(6), "Can you add a test?"), comment(bot("stamphog"), ago(5), "Approved.")])

        finding = self.assertFinding(evaluate(raw, enabled={4}), 4, days=6)

        self.assertIs(finding["needs_judgment"], True)

    def test_top_level_question_in_review_body_fires(self):
        raw = pr(reviews=[review(LOGIN, "COMMENTED", ago(4), body="Does this handle nulls?")])

        self.assertFinding(evaluate(raw, enabled={4}), 4, days=4)

    def test_my_question_on_my_own_pr_with_no_other_human_gives_nothing(self):
        cases = {
            "inline": mine(threads=[thread(tc(LOGIN, ago(4), "Should I rename this?"))]),
            "top_level": mine(comments=[comment(LOGIN, ago(4), "Anyone know why CI is red?"), comment(bot("stamphog"), ago(3), "CI report.")]),
        }
        for name, raw in cases.items():
            with self.subTest(case=name):
                self.assertNoFinding(evaluate(raw, enabled={4}))

    def test_my_question_in_thread_on_my_own_pr_with_another_human_fires(self):
        raw = mine(threads=[thread(tc(OTHER, ago(5), "Nit on naming."), tc(LOGIN, ago(4), "Do you mean rename it?"))])

        self.assertFinding(evaluate(raw, enabled={4}), 4, days=4)

    def test_two_questions_give_earliest_since_and_count(self):
        raw = pr(threads=[
            thread(tc(LOGIN, ago(3), "How does this scale?")),
            thread(tc(LOGIN, ago(5), "Why is this needed?")),
        ])

        finding = self.assertFinding(evaluate(raw, enabled={4}), 4, days=5)

        self.assertEqual(finding["since"], ago(5))
        self.assertRegex(finding["reason"], r"\b2\b[^.]*\bquestions\b")

    def test_excerpt_is_my_stripped_text_at_most_280_characters(self):
        body = "Why is `cache` needed here? " + "word " * 100 + "\n> alice wrote: quoted context"
        raw = pr(threads=[thread(tc(AUTHOR, ago(6), "Alice explains the change."), tc(LOGIN, ago(4), body))])

        finding = self.assertFinding(evaluate(raw, enabled={4}), 4)

        self.assertLessEqual(len(finding["excerpt"]), 280)
        self.assertTrue(finding["excerpt"].startswith("Why is needed here? word"), finding["excerpt"])
        self.assertNotIn("quoted context", finding["excerpt"])
        self.assertNotIn("Alice explains", finding["excerpt"])

    def test_top_level_question_with_truncated_comments_after_it_gives_incomplete(self):
        raw = pr(
            reviews=[review(LOGIN, "COMMENTED", ago(6), body="Does this handle nulls?")],
            comments=[comment(bot("stamphog"), ago(5), "CI report.")],
            truncated={"comments"},
        )

        self.assertIncomplete(evaluate(raw, enabled={4}), 4)


class Check5StaleApprovalTest(CheckTestCase):
    def test_new_commits_after_my_approval_fire(self):
        self.assertFinding(evaluate(stale_approval_pr(), enabled={5}), 5, "new_commits", days=4, group="waiting_on_others")

    def test_merge_only_commits_after_approval_give_check_1_not_check_5(self):
        raw = pr(reviews=[review(LOGIN, "APPROVED", ago(5), oid="a1")], commits=[commit("a1", ago(6)), commit("m1", ago(4), parents=2)])

        finding = self.assertFinding(evaluate(raw, enabled={1, 5}), 1, days=5)

        self.assertNotIn(5, finding["other_checks"])

    def test_truncated_comments_starting_after_approval_gives_incomplete(self):
        raw = stale_approval_pr(comments=[comment(OTHER, ago(2))], truncated={"comments"})

        self.assertIncomplete(evaluate(raw, enabled={5}), 5)

    def test_rebased_commit_with_old_date_uses_approval_time_for_clock(self):
        raw = pr(reviews=[review(LOGIN, "APPROVED", ago(5), oid="a1")], commits=[commit("a1", ago(9)), commit("b2", ago(8))])

        self.assertFinding(evaluate(raw, enabled={5}), 5, days=5)

    def test_oid_older_than_commit_window_fires(self):
        raw = pr(reviews=[review(LOGIN, "APPROVED", ago(10), oid="old")], commits=[commit("n1", ago(4))], truncated={"commits"})

        self.assertFinding(evaluate(raw, enabled={5}), 5, days=4)

    def test_author_activity_after_push_moves_since(self):
        raw = stale_approval_pr(comments=[comment(AUTHOR, ago(3), "Pushed a fix.")])

        self.assertFinding(evaluate(raw, enabled={5}), 5, days=3)

    def test_null_approval_commit_gives_nothing(self):
        raw = stale_approval_pr(reviews=[review(LOGIN, "APPROVED", ago(6), oid=None)])

        self.assertNoFinding(evaluate(raw, enabled={5}))


class Check6ReplyAwaitingMeTest(CheckTestCase):
    def test_bot_comment_last_in_thread_does_not_hide_the_reply(self):
        raw = pr(threads=[thread(
            tc(LOGIN, ago(6), "Consider caching this."),
            tc(OTHER, ago(4), "Not needed."),
            tc(bot("copilot"), ago(3), "Suggested fix."),
        )])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "reply", days=4)

    def test_truncated_comments_with_none_of_my_activity_visible_gives_incomplete(self):
        raw = pr(comments=[comment(OTHER, ago(4), "@haacked ping")], truncated={"comments"})

        self.assertIncomplete(evaluate(raw, enabled={6}), 6)

    def test_reply_to_me_in_thread_fires(self):
        self.assertFinding(evaluate(reply_pr(), enabled={6}), 6, "reply", days=4, group="waiting_on_me")

    def test_since_is_earliest_reply_after_my_last_comment(self):
        raw = pr(threads=[thread(tc(LOGIN, ago(6), "Consider caching this."), tc(OTHER, ago(5), "Hmm."), tc(AUTHOR, ago(3), "Agreed."))])

        self.assertFinding(evaluate(raw, enabled={6}), 6, days=5)

    def test_thread_where_i_answered_last_gives_nothing(self):
        raw = pr(threads=[thread(tc(LOGIN, ago(6), "Consider caching this."), tc(OTHER, ago(5), "Not needed."), tc(LOGIN, ago(4), "Fair enough."))])

        self.assertNoFinding(evaluate(raw, enabled={6}))

    def test_bot_reply_gives_nothing(self):
        raw = pr(threads=[thread(tc(LOGIN, ago(6), "Consider caching this."), tc(bot("copilot"), ago(4), "Suggested fix."))])

        self.assertNoFinding(evaluate(raw, enabled={6}))

    def test_truncated_thread_without_my_comment_in_window_is_skipped(self):
        raw = pr(threads=[thread(tc(OTHER, ago(5), "Still thinking."), tc(AUTHOR, ago(4), "Done."), truncated=True)])

        self.assertNoFinding(evaluate(raw, enabled={6}))

    def test_truncated_thread_with_my_comment_in_window_fires(self):
        raw = pr(threads=[thread(tc(LOGIN, ago(6), "Consider caching this."), tc(OTHER, ago(4), "Done."), truncated=True)])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "reply", days=4)

    def test_mention_in_issue_comment_after_my_last_activity_fires(self):
        raw = pr(comments=[comment(LOGIN, ago(6), "Thanks."), comment(OTHER, ago(4), "@haacked can you take a look")])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention", days=4, group="waiting_on_me")

    def test_mention_in_review_body_fires(self):
        raw = pr(reviews=[review(OTHER, "COMMENTED", ago(4), body="@haacked does this match what you wanted")])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention", days=4)

    def test_mention_in_thread_comment_fires(self):
        raw = pr(threads=[thread(tc(OTHER, ago(4), "cc @haacked"))])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention", days=4)

    def test_mention_with_no_activity_of_mine_fires(self):
        raw = pr(comments=[comment(OTHER, ago(4), "@haacked FYI")])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention", days=4)

    def test_capitalized_mention_matches(self):
        raw = pr(comments=[comment(OTHER, ago(4), "@Haacked can you take a look")])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention")

    def test_mention_followed_by_punctuation_matches(self):
        raw = pr(comments=[comment(OTHER, ago(4), "Thanks @haacked, merging soon")])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention")

    def test_non_mentions_give_nothing(self):
        bodies = {
            "suffix": "@haacked-bot ran the job",
            "email": "Write to email@haacked.com",
            "quote": "> @haacked said this\nI agree.",
            "inline_code": "Run `@haacked` literally.",
        }
        for name, body in bodies.items():
            with self.subTest(body=name):
                self.assertNoFinding(evaluate(pr(comments=[comment(OTHER, ago(4), body)]), enabled={6}))

    def test_mention_before_my_latest_activity_gives_nothing(self):
        raw = pr(comments=[comment(OTHER, ago(6), "@haacked ping"), comment(LOGIN, ago(5), "On it.")])

        self.assertNoFinding(evaluate(raw, enabled={6}))

    def test_bot_mention_gives_nothing(self):
        raw = pr(comments=[comment(bot("stamphog"), ago(4), "@haacked approved")])

        self.assertNoFinding(evaluate(raw, enabled={6}))

    def test_truncated_comments_after_my_latest_activity_gives_incomplete(self):
        raw = pr(
            reviews=[review(LOGIN, "COMMENTED", ago(8))],
            comments=[comment(OTHER, ago(4), "@haacked ping")],
            truncated={"comments"},
        )

        self.assertIncomplete(evaluate(raw, enabled={6}), 6)

    def test_earliest_candidate_wins(self):
        raw = reply_pr(comments=[comment(OTHER, ago(5), "@haacked another thing")])

        self.assertFinding(evaluate(raw, enabled={6}), 6, "mention", days=5)


class Check7ReviewRequestedTest(CheckTestCase):
    def test_review_window_that_starts_after_the_request_gives_incomplete(self):
        raw = request_pr(reviews=[review(bot("copilot"), "COMMENTED", ago(1))], truncated={"reviews"})

        self.assertIncomplete(evaluate(raw, enabled={7}), 7)

    def test_direct_request_older_than_threshold_fires(self):
        finding = self.assertFinding(evaluate(request_pr(), enabled={7}), 7, "requested", days=4, group="waiting_on_me")

        self.assertIs(finding["rerequested"], False)

    def test_request_younger_than_threshold_gives_nothing(self):
        self.assertNoFinding(evaluate(request_pr(when=ago(1)), enabled={7}))

    def test_team_only_request_gives_nothing(self):
        raw = pr(requests=[TEAM], events=[requested(TEAM, ago(4))])

        self.assertNoFinding(evaluate(raw, enabled={7}))

    def test_no_event_in_complete_timeline_falls_back_to_created_at(self):
        raw = request_pr(events=[], created=ago(5))

        finding = self.assertFinding(evaluate(raw, enabled={7}), 7, days=5)

        self.assertEqual(finding["since"], ago(5))

    def test_event_for_another_user_falls_back_to_created_at(self):
        raw = request_pr(events=[requested(OTHER, ago(4))], created=ago(9))

        self.assertFinding(evaluate(raw, enabled={7}), 7, days=9)

    def test_no_event_in_truncated_timeline_gives_incomplete(self):
        raw = request_pr(events=[force_pushed(ago(1))], truncated={"events"})

        self.assertIncomplete(evaluate(raw, enabled={7}), 7)

    def test_latest_request_event_sets_since(self):
        raw = request_pr(events=[requested(LOGIN, ago(9)), requested(LOGIN, ago(4))])

        self.assertFinding(evaluate(raw, enabled={7}), 7, days=4)

    def test_my_review_after_request_gives_nothing(self):
        raw = request_pr(when=ago(6), reviews=[review(LOGIN, "COMMENTED", ago(4))])

        self.assertNoFinding(evaluate(raw, enabled={7}))

    def test_request_after_my_earlier_review_is_a_rerequest(self):
        raw = request_pr(reviews=[review(LOGIN, "COMMENTED", ago(6))])

        finding = self.assertFinding(evaluate(raw, enabled={7}), 7, "rerequested", days=4)

        self.assertIs(finding["rerequested"], True)
        self.assertIn("re-requested", finding["reason"])

    def test_bot_authored_pr_still_fires(self):
        self.assertFinding(evaluate(request_pr(author=bot("dependabot")), enabled={7}), 7, days=4)

    def test_draft_gives_nothing(self):
        self.assertNoFinding(evaluate(request_pr(draft=True)))


class Check8MyPrStalledTest(CheckTestCase):
    def test_null_decision_with_truncated_reviews_gives_incomplete(self):
        raw = mine(reviews=[review("carol", "APPROVED", ago(4))], truncated={"reviews"})

        self.assertIncomplete(evaluate(raw, enabled={8}), 8)

    def test_older_changes_request_wins_a_same_day_tie(self):
        raw = changes_requested_pr(reviews=[
            review("bob", "CHANGES_REQUESTED", ago(4, 5)),
            review("carol", "CHANGES_REQUESTED", ago(4, 1)),
        ])

        finding = self.assertFinding(evaluate(raw, enabled={8}), 8, "changes_requested", days=4)

        self.assertEqual(finding["since"], ago(4, 5))

    def test_truncated_thread_gives_no_unaddressed_thread(self):
        raw = mine(threads=[thread(tc(OTHER, ago(4), "Makes sense."), truncated=True)])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_unaddressed_changes_request_fires_waiting_on_me(self):
        finding = self.assertFinding(evaluate(changes_requested_pr(), enabled={8}), 8, "changes_requested", days=4, group="waiting_on_me")

        self.assertEqual(finding["since"], ago(4))

    def test_commit_after_changes_request_gives_nothing(self):
        raw = changes_requested_pr(
            reviews=[review(OTHER, "CHANGES_REQUESTED", ago(5), oid="a1")],
            commits=[commit("a1", ago(6)), commit("b2", ago(4))],
        )

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_my_activity_after_changes_request_gives_nothing(self):
        activities = {
            "issue_comment": {"comments": [comment(LOGIN, ago(3), "Will fix.")]},
            "review": {"reviews": [review(OTHER, "CHANGES_REQUESTED", ago(4)), review(LOGIN, "COMMENTED", ago(3))]},
            "thread_comment": {"threads": [thread(tc(OTHER, ago(4), "Rename this."), tc(LOGIN, ago(3), "Done."))]},
        }
        for name, kw in activities.items():
            with self.subTest(activity=name):
                self.assertNoFinding(evaluate(changes_requested_pr(**kw), enabled={8}))

    def test_truncated_comments_starting_after_changes_request_gives_incomplete(self):
        raw = changes_requested_pr(comments=[comment(OTHER, ago(2))], truncated={"comments"})

        self.assertIncomplete(evaluate(raw, enabled={8}), 8)

    def test_bot_changes_request_gives_nothing(self):
        raw = mine(reviews=[review(bot("reviewhog"), "CHANGES_REQUESTED", ago(4))])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_changes_request_superseded_by_approval_is_not_changes_requested(self):
        raw = mine(reviews=[review(OTHER, "CHANGES_REQUESTED", ago(6)), review(OTHER, "APPROVED", ago(4))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "approved_ready", days=4)

    def test_unaddressed_human_thread_fires(self):
        raw = mine(threads=[thread(tc(OTHER, ago(4), "Rename this."))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "unaddressed_thread", days=4, group="waiting_on_me")

    def test_unaddressed_thread_since_is_last_human_comment(self):
        raw = mine(threads=[thread(tc(OTHER, ago(8), "Rename this."), tc(LOGIN, ago(7), "To what?"), tc(OTHER, ago(4), "To fetch_all."), tc(bot("copilot"), ago(1), "Suggestion."))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "unaddressed_thread", days=4)

    def test_thread_i_answered_last_gives_nothing(self):
        raw = mine(threads=[thread(tc(OTHER, ago(5), "Rename this."), tc(LOGIN, ago(4), "Done."))])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_outdated_thread_gives_nothing(self):
        raw = mine(threads=[thread(tc(OTHER, ago(4), "Rename this."), outdated=True)])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_resolved_thread_gives_nothing(self):
        raw = mine(threads=[thread(tc(OTHER, ago(4), "Rename this."), resolved=True)])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_bot_thread_gives_nothing(self):
        raw = mine(threads=[thread(tc(bot("copilot"), ago(4), "Possible null dereference."))])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_thread_i_started_gives_no_unaddressed_thread(self):
        raw = mine(threads=[thread(tc(LOGIN, ago(6), "Note to reviewers."), tc(OTHER, ago(4), "Makes sense."))])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_approved_and_unmerged_fires_waiting_on_me(self):
        raw = mine(decision="APPROVED", reviews=[review(OTHER, "APPROVED", ago(4))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "approved_ready", days=4, group="waiting_on_me")

    def test_since_is_latest_human_approval(self):
        raw = mine(decision="APPROVED", reviews=[review(OTHER, "APPROVED", ago(6)), review("carol", "APPROVED", ago(4))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "approved_ready", days=4)

    def test_approved_in_merge_queue_fires_waiting_on_others(self):
        raw = mine(decision="APPROVED", merge_queue=True, reviews=[review(OTHER, "APPROVED", ago(4))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "merge_queue", group="waiting_on_others")

    def test_approved_with_conflicts_or_failing_ci(self):
        cases = {
            "approved_conflicts": {"mergeable": "CONFLICTING", "ci": "FAILURE"},
            "approved_ci_failing": {"ci": "ERROR"},
            "approved_ready": {"mergeable": "UNKNOWN", "ci": None},
        }
        for code, kw in cases.items():
            with self.subTest(code=code):
                raw = mine(decision="APPROVED", reviews=[review(OTHER, "APPROVED", ago(4))], **kw)
                self.assertFinding(evaluate(raw, enabled={8}), 8, code, group="waiting_on_me")

    def test_null_decision_with_human_approval_and_no_requests_counts_as_approved(self):
        raw = mine(decision=None, reviews=[review(OTHER, "APPROVED", ago(4))])

        self.assertFinding(evaluate(raw, enabled={8}), 8, "approved_ready")

    def test_null_decision_with_pending_request_is_not_approved(self):
        raw = mine(decision=None, reviews=[review(OTHER, "APPROVED", ago(4))], requests=["carol"])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_null_decision_with_only_bot_approval_is_not_approved(self):
        raw = mine(decision=None, reviews=[review(bot("stamphog"), "APPROVED", ago(4))])

        self.assertNoFinding(evaluate(raw, enabled={8}))

    def test_someone_elses_pr_gives_no_check_8(self):
        raw = approved_pr(decision="APPROVED", threads=[thread(tc(OTHER, ago(4), "Rename this."))])

        self.assertNoFinding(evaluate(raw, enabled={8}))


class SkippedPrTest(CheckTestCase):
    def test_draft_skips_every_check(self):
        for check_id, build in BASE_FIXTURES.items():
            with self.subTest(check=check_id):
                self.assertFinding(evaluate(build(), enabled={check_id}), check_id)
                self.assertNoFinding(evaluate(build(draft=True)))

    def test_closed_or_merged_skips_every_check(self):
        for state in ("CLOSED", "MERGED"):
            for check_id, build in BASE_FIXTURES.items():
                with self.subTest(state=state, check=check_id):
                    self.assertNoFinding(evaluate(build(state=state)))


class DedupeTest(CheckTestCase):
    def test_check_7_beats_check_1(self):
        raw = approved_pr(requests=[LOGIN], events=[requested(LOGIN, ago(3))])

        finding = self.assertFinding(evaluate(raw), 7)

        self.assertEqual(finding["other_checks"], [1])

    def test_check_6_beats_check_2(self):
        raw = pr(
            reviews=[review(LOGIN, "COMMENTED", ago(5))],
            threads=[thread(tc(LOGIN, ago(5), "Consider caching this."), tc(OTHER, ago(3), "Not needed here."))],
        )

        finding = self.assertFinding(evaluate(raw), 6)

        self.assertEqual(finding["other_checks"], [2])

    def test_check_3_beats_check_4(self):
        raw = pushed_after_review_pr(threads=[thread(tc(LOGIN, ago(6), "Why is this needed?"))])

        finding = self.assertFinding(evaluate(raw), 3)

        self.assertEqual(finding["other_checks"], [4])

    def test_check_2_beats_check_4(self):
        raw = commented_pr(threads=[thread(tc(LOGIN, ago(4), "Why is this needed?"))])

        finding = self.assertFinding(evaluate(raw), 2)

        self.assertEqual(finding["other_checks"], [4])

    def test_other_checks_are_sorted(self):
        raw = commented_pr(
            requests=[LOGIN],
            events=[requested(LOGIN, ago(3))],
            threads=[thread(tc(LOGIN, ago(4), "Why is this needed?"))],
        )

        finding = self.assertFinding(evaluate(raw), 7)

        self.assertEqual(finding["other_checks"], [2, 4])

    def test_candidate_below_threshold_does_not_take_part(self):
        raw = approved_pr(requests=[LOGIN], events=[requested(LOGIN, ago(1))])

        finding = self.assertFinding(evaluate(raw), 1)

        self.assertEqual(finding["other_checks"], [])

    def test_single_check_has_empty_other_checks(self):
        finding = self.assertFinding(evaluate(approved_pr()), 1)

        self.assertEqual(finding["other_checks"], [])


class FindingShapeTest(CheckTestCase):
    def test_finding_has_every_schema_field_except_notify(self):
        finding, _ = evaluate(approved_pr())

        self.assertTrue(FINDING_FIELDS - {"notify"} <= set(finding), FINDING_FIELDS - set(finding))

    def test_finding_identifies_the_pr(self):
        finding, _ = evaluate(approved_pr(number=42, title="Add gizmos"))

        self.assertEqual(
            {k: finding[k] for k in ("key", "url", "repo", "number", "title", "author")},
            {"key": f"{url(42)}#1", "url": url(42), "repo": REPO, "number": 42, "title": "Add gizmos", "author": AUTHOR},
        )

    def test_timestamps_are_utc_strings_ending_in_z(self):
        finding, _ = evaluate(approved_pr())

        self.assertEqual(finding["since"], ago(4))
        self.assertTrue(finding["last_activity_at"].endswith("Z"))

    def test_last_activity_ignores_bots(self):
        raw = approved_pr(comments=[comment(OTHER, ago(2), "Any update?"), comment(bot("stamphog"), ago(1), "Ping.")])

        finding, _ = evaluate(raw, enabled={1})

        self.assertEqual(finding["last_activity_at"], ago(2))

    def test_last_activity_includes_force_pushes(self):
        raw = approved_pr(events=[force_pushed(ago(1))])

        finding, _ = evaluate(raw, enabled={1})

        self.assertEqual(finding["last_activity_at"], ago(1))

    def test_excerpt_and_rerequested_are_null_outside_their_checks(self):
        for check_id, build in BASE_FIXTURES.items():
            with self.subTest(check=check_id):
                finding = self.assertFinding(evaluate(build(), enabled={check_id}), check_id)
                if check_id != 4:
                    self.assertIsNone(finding["excerpt"])
                if check_id not in (3, 7):
                    self.assertIsNone(finding["rerequested"])
                if check_id != 4:
                    self.assertIs(finding["needs_judgment"], False)

    def test_suggested_action_has_no_unfilled_placeholders(self):
        for check_id, build in BASE_FIXTURES.items():
            with self.subTest(check=check_id):
                finding, _ = evaluate(build(), enabled={check_id})
                self.assertTrue(finding["suggested_action"].strip())
                self.assertNotIn("{", finding["suggested_action"])


THRESHOLDS = {n: 2 for n in range(1, 9)}


def check_1_finding(days, number=1):
    finding, _ = evaluate(approved_pr(number=number, reviews=[review(LOGIN, "APPROVED", ago(days))]), enabled={1})
    return finding


def state_with(finding, days_stale, since=None):
    entry = {"notified_at": ago(1), "days_stale": days_stale, "since": since or finding["since"]}
    return {"version": 1, "items": {finding["key"]: entry}}


class ApplyStateTest(unittest.TestCase):
    def test_no_entry_notifies(self):
        [result] = pr_followups.apply_state([check_1_finding(4)], {"version": 1, "items": {}}, THRESHOLDS)

        self.assertIs(result["notify"], True)

    def test_same_since_below_aging_bound_is_suppressed(self):
        finding = check_1_finding(4)

        [result] = pr_followups.apply_state([finding], state_with(finding, 3), THRESHOLDS)

        self.assertIs(result["notify"], False)

    def test_same_since_exactly_at_aging_bound_notifies(self):
        finding = check_1_finding(5)

        [result] = pr_followups.apply_state([finding], state_with(finding, 3), THRESHOLDS)

        self.assertIs(result["notify"], True)

    def test_changed_since_notifies(self):
        finding = check_1_finding(4)

        [result] = pr_followups.apply_state([finding], state_with(finding, 3, since=ago(9)), THRESHOLDS)

        self.assertIs(result["notify"], True)

    def test_per_check_threshold_sets_aging_bound(self):
        finding = check_1_finding(5)

        [result] = pr_followups.apply_state([finding], state_with(finding, 3), {**THRESHOLDS, 1: 5})

        self.assertIs(result["notify"], False)


class RecordTest(unittest.TestCase):
    def setUp(self):
        self.first = dict(check_1_finding(4, number=1), notify=True)
        self.second = dict(check_1_finding(5, number=2), notify=True)
        self.last_scan = {"schema_version": 1, "findings": [self.first, self.second], "incomplete": []}

    def test_writes_entries_only_for_sent_keys(self):
        state = pr_followups.record({"version": 1, "items": {}}, self.last_scan, [self.first["key"]], NOW)

        self.assertEqual(
            state["items"],
            {self.first["key"]: {"notified_at": iso(NOW), "scanned_at": None, "days_stale": 4, "since": ago(4)}},
        )

    def test_older_scan_keeps_the_entry_a_newer_scan_recorded(self):
        newer = {"notified_at": ago(1), "scanned_at": ago(1), "days_stale": 6, "since": ago(4)}
        state = {"version": 1, "items": {self.first["key"]: newer}}
        older_scan = dict(self.last_scan, generated_at=ago(3))

        result = pr_followups.record(state, older_scan, [self.first["key"]], NOW)

        self.assertEqual(result["items"][self.first["key"]], newer)

    def test_newer_scan_replaces_the_entry(self):
        older = {"notified_at": ago(3), "scanned_at": ago(3), "days_stale": 2, "since": ago(4)}
        state = {"version": 1, "items": {self.first["key"]: older}}
        newer_scan = dict(self.last_scan, generated_at=ago(1))

        result = pr_followups.record(state, newer_scan, [self.first["key"]], NOW)

        self.assertEqual(result["items"][self.first["key"]]["scanned_at"], ago(1))

    def test_keeps_recent_keys_absent_from_last_scan(self):
        missed = f"{url(98)}#1"
        recent = {"notified_at": ago(89), "days_stale": 3, "since": ago(92)}
        state = {"version": 1, "items": {missed: recent}}

        result = pr_followups.record(state, self.last_scan, [self.second["key"]], NOW)

        self.assertEqual(result["items"][missed], recent)

    def test_prunes_keys_notified_before_the_retention_window(self):
        gone = f"{url(99)}#1"
        old = {"notified_at": ago(91), "days_stale": 3, "since": ago(94)}
        state = {"version": 1, "items": {gone: old, self.first["key"]: old}}

        result = pr_followups.record(state, self.last_scan, [self.second["key"]], NOW)

        self.assertEqual(set(result["items"]), {self.second["key"]})

    def test_prunes_absent_key_without_a_notified_time(self):
        gone = f"{url(99)}#1"
        state = {"version": 1, "items": {gone: {"days_stale": 3, "since": ago(6)}}}

        result = pr_followups.record(state, self.last_scan, [self.second["key"]], NOW)

        self.assertNotIn(gone, result["items"])

    def test_unknown_key_raises(self):
        with self.assertRaises(ValueError):
            pr_followups.record({"version": 1, "items": {}}, self.last_scan, [f"{url(99)}#1"], NOW)

    def test_notify_false_key_raises(self):
        self.second["notify"] = False

        with self.assertRaises(ValueError):
            pr_followups.record({"version": 1, "items": {}}, self.last_scan, [self.second["key"]], NOW)


def gh_fields(args):
    fields, ids = {}, []
    for flag, value in zip(args, args[1:]):
        if flag in ("-f", "-F", "--raw-field", "--field"):
            name, _, val = value.partition("=")
            if name == "ids[]":
                ids.append(val)
            else:
                fields[name] = val
    return fields, ids


class FakeGh:
    """Answers the login, search, and detail calls that scan makes through subprocess.run."""

    def __init__(self, prs=(), searches=None, login=LOGIN, fail=None, issue_counts=None):
        self.nodes = {node["id"]: node for node in prs}
        self.searches = searches if searches is not None else {f"involves:{login}": [[node["id"] for node in prs]]}
        self.login = login
        self.fail = fail
        self.issue_counts = issue_counts or {}
        self.calls = []
        self.search_calls = []
        self.detail_batches = []

    def __call__(self, args, **kwargs):
        args = list(args)
        self.calls.append(args)
        if args == LOGIN_ARGV:
            return self.reply(args, "login", self.login + "\n")
        if args[:3] != ["gh", "api", "graphql"]:
            raise AssertionError(f"unexpected command: {args}")
        fields, ids = gh_fields(args)
        query = fields.get("query")
        if query == pr_followups.SEARCH_QUERY:
            q, cursor = fields["q"], fields.get("cursor")
            self.search_calls.append((q, cursor))
            return self.reply(args, "search", json.dumps(self.search(q, cursor)))
        if query == pr_followups.DETAIL_QUERY:
            self.detail_batches.append(ids)
            return self.reply(args, "detail", json.dumps({"data": {"nodes": [self.nodes.get(i) for i in ids]}}))
        raise AssertionError(f"unexpected graphql query: {args}")

    def reply(self, args, kind, stdout):
        if self.fail == kind:
            return subprocess_result(args, 1, "", "gh: HTTP 502: Bad Gateway")
        return subprocess_result(args, 0, stdout, "")

    def search(self, q, cursor):
        tokens = set(q.split())
        key, pages = next(((k, p) for k, p in self.searches.items() if set(k.split()) <= tokens), (None, []))
        index = 0 if cursor is None else int(cursor.removeprefix("cursor-"))
        page = pages[index] if index < len(pages) else []
        has_next = index + 1 < len(pages)
        count = self.issue_counts.get(key, sum(len(p) for p in pages))
        return {"data": {"search": {
            "issueCount": count,
            "pageInfo": {"hasNextPage": has_next, "endCursor": f"cursor-{index + 1}" if has_next else None},
            "nodes": [{"id": node_id} for node_id in page],
        }}}

    def queries(self):
        return [q for q, cursor in self.search_calls if cursor is None]

    def fetched_ids(self):
        return [node_id for batch in self.detail_batches for node_id in batch]


def subprocess_result(args, code, stdout, stderr):
    return subprocess.CompletedProcess(args, code, stdout=stdout, stderr=stderr)


SEARCH_KINDS = ("involves", "reviewed-by", "user-review-requested")


def search_kind(q):
    [kind] = [t.split(":")[0] for t in q.split() if t.split(":")[0] in SEARCH_KINDS]
    return kind


class CliTestCase(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.state_dir = Path(tmp.name)
        env = mock.patch.dict(os.environ, {"PR_FOLLOWUPS_STATE_DIR": str(self.state_dir)})
        env.start()
        self.addCleanup(env.stop)

    def run_main(self, gh, *argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch("subprocess.run", gh), mock.patch.object(pr_followups, "now", return_value=NOW), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            try:
                code = pr_followups.main(list(argv))
            except SystemExit as exit:
                code = exit.code
        return code, out.getvalue(), err.getvalue()

    def scan(self, gh, *args):
        code, out, err = self.run_main(gh, "scan", *args)
        self.assertEqual(code, 0, f"stdout={out!r} stderr={err!r}")
        return json.loads(out)

    def numbers(self, output):
        return [finding["number"] for finding in output["findings"]]

    @property
    def state_file(self):
        return self.state_dir / "state.json"

    @property
    def last_scan_file(self):
        return self.state_dir / "last-scan.json"


class ScanCliTest(CliTestCase):
    def test_login_comes_from_gh_api_user(self):
        gh = FakeGh(login="octocat")

        output = self.scan(gh)

        self.assertEqual(gh.calls[0], LOGIN_ARGV)
        self.assertEqual(output["login"], "octocat")
        self.assertTrue(all("octocat" in q and "haacked" not in q for q in gh.queries()), gh.queries())

    def test_three_searches_carry_the_right_qualifiers(self):
        gh = FakeGh()

        self.scan(gh)

        queries = {f"{search_kind(q)}:haacked": set(q.split()) for q in gh.queries()}
        self.assertEqual(set(queries), {"involves:haacked", "reviewed-by:haacked", "user-review-requested:haacked"})
        for kind, tokens in queries.items():
            with self.subTest(kind=kind):
                self.assertTrue({"is:pr", "is:open", "archived:false"} <= tokens, tokens)
        self.assertIn("updated:>=2026-10-20", queries["involves:haacked"])
        self.assertIn("updated:>=2026-10-20", queries["reviewed-by:haacked"])
        self.assertFalse(any(t.startswith("updated:") for t in queries["user-review-requested:haacked"]))

    def test_lookback_days_sets_updated_date(self):
        gh = FakeGh()

        self.scan(gh, "--lookback-days", "7")

        dated = [q for q in gh.queries() if "user-review-requested:" not in q]
        self.assertEqual(len(dated), 2)
        self.assertTrue(all("updated:>=2026-11-12" in q.split() for q in dated), dated)

    def test_search_pagination_follows_end_cursor(self):
        gh = FakeGh(prs=[pr(number=1), pr(number=2)], searches={"involves:haacked": [["PR_1"], ["PR_2"]]})

        self.scan(gh)

        involves_cursors = [cursor for q, cursor in gh.search_calls if "involves:haacked" in q.split()]
        self.assertEqual(involves_cursors, [None, "cursor-1"])
        self.assertEqual(sorted(gh.fetched_ids()), ["PR_1", "PR_2"])

    def test_first_page_omits_cursor_argument(self):
        gh = FakeGh()

        self.scan(gh)

        search_args = [args for args in gh.calls if args[:3] == ["gh", "api", "graphql"]]
        self.assertTrue(search_args)
        self.assertTrue(all(not any(a.startswith("cursor=") for a in args) for args in search_args))

    def test_org_and_repo_issue_one_search_per_kind_and_scope(self):
        gh = FakeGh()

        output = self.scan(gh, "--org", "PostHog", "--repo", "haacked/dotfiles")

        pairs = []
        for q in gh.queries():
            tokens = q.split()
            kind = search_kind(q)
            scopes = [t for t in tokens if t.startswith(("user:", "repo:", "org:"))]
            self.assertEqual(len(scopes), 1, q)
            pairs.append((kind, scopes[0]))
        expected = [(kind, scope) for kind in SEARCH_KINDS for scope in ("user:PostHog", "repo:haacked/dotfiles")]
        self.assertEqual(sorted(pairs), sorted(expected))
        self.assertEqual(output["scope"], {"orgs": ["PostHog"], "repos": ["haacked/dotfiles"], "lookback_days": 30})

    def test_details_are_batched_10_per_call(self):
        prs = [pr(number=n) for n in range(1, 26)]
        gh = FakeGh(prs=prs)

        self.scan(gh)

        self.assertEqual(sorted(len(batch) for batch in gh.detail_batches), [5, 10, 10])
        self.assertEqual(sorted(gh.fetched_ids()), sorted(node["id"] for node in prs))

    def test_ids_are_unioned_with_no_duplicate_fetch(self):
        prs = [pr(number=n) for n in (1, 2, 3)]
        gh = FakeGh(prs=prs, searches={
            "involves:haacked": [["PR_1", "PR_2"]],
            "reviewed-by:haacked": [["PR_2", "PR_3"]],
            "user-review-requested:haacked": [["PR_3"]],
        })

        self.scan(gh)

        self.assertEqual(sorted(gh.fetched_ids()), ["PR_1", "PR_2", "PR_3"])

    def test_gh_failure_prints_error_and_exits_1(self):
        for stage in ("login", "search", "detail"):
            with self.subTest(stage=stage):
                gh = FakeGh(prs=[approved_pr()], fail=stage)

                code, out, _ = self.run_main(gh, "scan")

                self.assertEqual(code, 1)
                self.assertIn("error", json.loads(out))

    def test_last_scan_is_written_under_state_dir_and_matches_stdout(self):
        gh = FakeGh(prs=[approved_pr()])

        code, out, _ = self.run_main(gh, "scan")

        self.assertEqual(code, 0)
        self.assertEqual(out.strip(), self.last_scan_file.read_text().strip())

    def test_output_header(self):
        output = self.scan(FakeGh())

        self.assertEqual(
            {k: output[k] for k in ("schema_version", "generated_at", "login", "thresholds", "checks", "scope", "findings", "incomplete")},
            {
                "schema_version": 1,
                "generated_at": "2026-11-19T15:45:00Z",
                "login": LOGIN,
                "thresholds": {str(n): 2 for n in range(1, 9)},
                "checks": [1, 2, 3, 4, 5, 6, 7, 8],
                "scope": {"orgs": [], "repos": [], "lookback_days": 30},
                "findings": [],
                "incomplete": [],
            },
        )

    def test_search_over_1000_results_is_reported_incomplete(self):
        gh = FakeGh(issue_counts={"involves:haacked": 1500})

        output = self.scan(gh)

        self.assertTrue(
            any(entry["detail"].startswith("search capped at 1000 results") for entry in output["incomplete"]),
            output["incomplete"],
        )

    def test_scan_finding_has_exactly_the_schema_fields(self):
        output = self.scan(FakeGh(prs=[approved_pr()]))

        [finding] = output["findings"]
        self.assertEqual(set(finding), FINDING_FIELDS)
        self.assertEqual(finding["key"], f"{url(1)}#1")
        self.assertIs(finding["notify"], True)

    def test_check_incomplete_entries_reach_the_output(self):
        output = self.scan(FakeGh(prs=[approved_pr(comments=[comment(OTHER, ago(2))], truncated={"comments"})]))

        self.assertEqual(output["findings"], [])
        self.assertIn(url(1), [entry["url"] for entry in output["incomplete"]])

    def test_output_order_is_me_group_first_then_days_stale_descending_then_key(self):
        prs = [
            approved_pr(number=1, reviews=[review(LOGIN, "APPROVED", ago(5))]),
            request_pr(number=2, when=ago(2)),
            approved_pr(number=3, reviews=[review(LOGIN, "APPROVED", ago(8))]),
            request_pr(number=4, when=ago(4)),
            approved_pr(number=5, reviews=[review(LOGIN, "APPROVED", ago(5))]),
        ]

        output = self.scan(FakeGh(prs=prs))

        self.assertEqual(self.numbers(output), [4, 2, 3, 1, 5])

    def test_schema_doc_field_table_matches_finding_keys(self):
        output = self.scan(FakeGh(prs=[approved_pr()]))

        self.assertEqual(documented_finding_fields(self), set(output["findings"][0]))


def documented_finding_fields(test):
    tables, current = [], []
    for line in SCHEMA_DOC.read_text().splitlines():
        if line.lstrip().startswith("|"):
            current.append(line)
        elif current:
            tables.append(current)
            current = []
    if current:
        tables.append(current)
    for table in tables:
        names = set()
        for row in table:
            first = row.strip().strip("|").split("|")[0].strip()
            match = re.fullmatch(r"`([^`]+)`", first)
            if match:
                names.add(match.group(1).split(".")[-1])
        if {"key", "check_id"} <= names:
            return names
    test.fail(f"{SCHEMA_DOC} has no table whose first column lists `key` and `check_id`")


class ThresholdAndToggleCliTest(CliTestCase):
    def test_per_check_threshold_silences_check_3_while_check_1_fires(self):
        gh = FakeGh(prs=[pushed_after_review_pr(number=1), approved_pr(number=2)])

        output = self.scan(gh, "--threshold", "3=5")

        self.assertEqual([(f["number"], f["check_id"]) for f in output["findings"]], [(2, 1)])
        self.assertEqual(output["thresholds"]["3"], 5)

    def test_days_0_fires_immediately(self):
        gh = FakeGh(prs=[approved_pr(reviews=[review(LOGIN, "APPROVED", ago(hours=1))])])

        output = self.scan(gh, "--days", "0")

        [finding] = output["findings"]
        self.assertEqual((finding["check_id"], finding["days_stale"]), (1, 0))

    def test_checks_limits_enabled_checks(self):
        gh = FakeGh(prs=[approved_pr(number=1), request_pr(number=2)])

        output = self.scan(gh, "--checks", "1,2")

        self.assertEqual(self.numbers(output), [1])
        self.assertEqual(output["checks"], [1, 2])

    def test_skip_removes_a_check(self):
        gh = FakeGh(prs=[reply_pr()])

        output = self.scan(gh, "--skip", "6")

        self.assertEqual(output["findings"], [])
        self.assertEqual(output["checks"], [1, 2, 3, 4, 5, 7, 8])

    def test_usage_errors_exit_2(self):
        cases = {
            "unknown_check_threshold": ["--threshold", "9=1"],
            "non_integer_threshold": ["--threshold", "3=abc"],
            "empty_enabled_set": ["--checks", "1", "--skip", "1"],
            "negative_days": ["--days", "-1"],
            "check_out_of_range": ["--checks", "9"],
            "skip_out_of_range": ["--skip", "0"],
        }
        for name, args in cases.items():
            with self.subTest(case=name):
                code, _, _ = self.run_main(FakeGh(), "scan", *args)
                self.assertEqual(code, 2)


class StateCliTest(CliTestCase):
    def test_malformed_state_file_warns_and_is_treated_as_empty(self):
        self.state_file.write_text("{not json")

        code, out, err = self.run_main(FakeGh(prs=[approved_pr()]), "scan")

        self.assertEqual(code, 0)
        self.assertTrue(err.strip())
        self.assertIs(json.loads(out)["findings"][0]["notify"], True)

    def test_record_key_containing_hash_writes_state(self):
        output = self.scan(FakeGh(prs=[approved_pr()]))
        key = output["findings"][0]["key"]
        self.assertIn("#", key)

        code, _, err = self.run_main(FakeGh(), "record", "--sent", key)

        self.assertEqual(code, 0, err)
        state = json.loads(self.state_file.read_text())
        self.assertEqual(state["items"][key]["days_stale"], 4)
        self.assertEqual(state["items"][key]["since"], ago(4))

    def test_record_with_scan_id_survives_a_later_scan(self):
        output = self.scan(FakeGh(prs=[approved_pr()]))
        key = output["findings"][0]["key"]
        later = dict(output, scan_id="20991231T000000000000Z", findings=[])
        self.last_scan_file.write_text(json.dumps(later))

        code, _, err = self.run_main(FakeGh(), "record", "--scan", output["scan_id"], "--sent", key)

        self.assertEqual(code, 0, err)
        self.assertIn(key, json.loads(self.state_file.read_text())["items"])

    def test_record_rejects_a_scan_id_that_is_not_one(self):
        self.scan(FakeGh(prs=[approved_pr()]))

        code, _, _ = self.run_main(FakeGh(), "record", "--scan", "../state", "--sent", f"{url(1)}#1")

        self.assertEqual(code, 2)

    def test_scan_keeps_only_the_newest_scans(self):
        scans = self.state_dir / "scans"
        scans.mkdir(parents=True)
        for day in range(1, 13):
            (scans / f"200001{day:02d}T000000000000Z.json").write_text("{}")

        output = self.scan(FakeGh(prs=[approved_pr()]))

        kept = sorted(p.name for p in scans.glob("*.json"))
        self.assertEqual(len(kept), pr_followups.SCANS_KEPT)
        self.assertIn(f"{output['scan_id']}.json", kept)

    def test_recorded_finding_is_suppressed_on_next_scan(self):
        gh = FakeGh(prs=[approved_pr()])
        key = self.scan(gh)["findings"][0]["key"]
        self.run_main(FakeGh(), "record", "--sent", key)

        output = self.scan(FakeGh(prs=[approved_pr()]))

        self.assertIs(output["findings"][0]["notify"], False)

    def test_record_unknown_key_exits_1_and_leaves_state_unchanged(self):
        key = self.scan(FakeGh(prs=[approved_pr()]))["findings"][0]["key"]
        self.run_main(FakeGh(), "record", "--sent", key)
        before = self.state_file.read_bytes()

        code, _, _ = self.run_main(FakeGh(), "record", "--sent", f"{url(99)}#1")

        self.assertEqual(code, 1)
        self.assertEqual(self.state_file.read_bytes(), before)

    def test_record_notify_false_key_exits_1(self):
        key = self.scan(FakeGh(prs=[approved_pr()]))["findings"][0]["key"]
        self.run_main(FakeGh(), "record", "--sent", key)
        self.scan(FakeGh(prs=[approved_pr()]))
        before = self.state_file.read_bytes()

        code, _, _ = self.run_main(FakeGh(), "record", "--sent", key)

        self.assertEqual(code, 1)
        self.assertEqual(self.state_file.read_bytes(), before)

    def test_record_write_is_atomic(self):
        output = self.scan(FakeGh(prs=[approved_pr(number=1), approved_pr(number=2)]))
        first, second = (finding["key"] for finding in output["findings"])
        self.run_main(FakeGh(), "record", "--sent", first)
        before = self.state_file.read_bytes()

        with mock.patch("os.replace", side_effect=OSError("disk full")):
            with contextlib.suppress(OSError):
                self.run_main(FakeGh(), "record", "--sent", second)

        self.assertEqual(self.state_file.read_bytes(), before)

    def test_last_scan_write_is_atomic(self):
        self.scan(FakeGh(prs=[approved_pr(number=1)]))
        before = self.last_scan_file.read_bytes()

        with mock.patch("os.replace", side_effect=OSError("disk full")):
            with contextlib.suppress(OSError):
                self.run_main(FakeGh(prs=[approved_pr(number=2)]), "scan")

        self.assertEqual(self.last_scan_file.read_bytes(), before)


if __name__ == "__main__":
    unittest.main()
