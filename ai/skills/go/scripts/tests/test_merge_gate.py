import importlib.util
import io
import json
from pathlib import Path
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "merge-gate.py"
SPEC = importlib.util.spec_from_file_location("merge_gate", SCRIPT)
merge_gate = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(merge_gate)

HEAD = "a" * 40
OLD = "b" * 40
LABELED = "2026-11-04T10:00:00Z"
REVIEWHOG_DONE = "2026-11-04T10:05:00Z"
ADDRESSED = "2026-11-04T11:00:00Z"
LATER = "2026-11-04T12:00:00Z"


def review(login, state, commit=HEAD, at=LATER, kind="User", body="", association="MEMBER"):
    return {"login": login, "type": kind, "state": state, "commit_id": commit, "submitted_at": at, "body": body, "association": association}


def stamphog(state="APPROVED", commit=HEAD, at=LATER):
    return review("stamphog[bot]", state, commit, at, "Bot", "**Approved.**")


def reviewhog_review(at=REVIEWHOG_DONE):
    return review("posthog[bot]", "COMMENTED", OLD, at, "Bot", "**PostHog Review** <!-- reviewhog:published:1 -->")


ALICE = {"login": "alice", "type": "User"}
AUTHOR = {"login": "haacked", "type": "User"}
COPILOT = {"login": "copilot-pull-request-reviewer", "type": "Bot"}


def thread(resolved, *authors):
    return {"resolved": resolved, "authors": list(authors), "url": "u1"}


def requested(login, kind="User", at=LABELED, event="review_requested"):
    return {"event": event, "reviewer": {"login": login, "type": kind}, "created_at": at}


def base_data(owner="PostHog"):
    return {
        "repo": {"owner": owner, "name": "posthog", "default_branch": "main", "default_merge_method": "SQUASH", "allowed_merge_methods": ["SQUASH", "MERGE"]},
        "pr": {
            "number": 7,
            "url": f"https://github.com/{owner}/posthog/pull/7",
            "state": "OPEN",
            "is_draft": False,
            "head_sha": HEAD,
            "base": "main",
            "author": "haacked",
            "review_decision": "",
            "mergeable": "MERGEABLE",
            "checks": [{"name": "tests", "state": "SUCCESS", "bucket": "pass"}, {"name": "lint", "state": "SKIPPED", "bucket": "skipping"}],
            "review_requests": [],
        },
        "reviews": [],
        "review_comments": [],
        "issue_comments": [],
        "timeline": [],
        "threads": [],
    }


def posthog_ready():
    data = base_data()
    data["timeline"].append({"event": "labeled", "label": "posthog-review", "created_at": LABELED})
    data["reviews"] += [reviewhog_review(), stamphog()]
    data["pr"]["review_decision"] = "APPROVED"
    return data


def haacked_ready():
    return base_data("haacked")


def decide(data, head=HEAD, addressed=ADDRESSED, reviewhog=True):
    return merge_gate.decide(data, head, addressed, reviewhog)


class MergeGateTest(unittest.TestCase):
    def assert_refused(self, data, fragment, **kwargs):
        verdict = decide(data, **kwargs)
        self.assertFalse(verdict["merge"], verdict)
        self.assertTrue(any(fragment in reason for reason in verdict["reasons"]), verdict["reasons"])
        return verdict

    def assert_merges(self, data, **kwargs):
        verdict = decide(data, **kwargs)
        self.assertTrue(verdict["merge"], verdict["reasons"])
        return verdict


class CommonRulesTest(MergeGateTest):
    def test_posthog_ready_pr_merges_with_default_method(self):
        verdict = self.assert_merges(posthog_ready())
        self.assertEqual(verdict["method"], "squash")
        self.assertEqual(verdict["approved_by"], ["stamphog[bot]"])
        self.assertEqual(verdict["policy"], "posthog")

    def test_closed_pr_is_refused(self):
        data = posthog_ready()
        data["pr"]["state"] = "MERGED"
        self.assert_refused(data, "the PR is merged")

    def test_draft_is_refused(self):
        data = posthog_ready()
        data["pr"]["is_draft"] = True
        self.assert_refused(data, "draft")

    def test_moved_head_is_refused(self):
        data = posthog_ready()
        data["pr"]["head_sha"] = OLD
        self.assert_refused(data, "not the expected")

    def test_conflicting_and_unknown_mergeability_are_refused(self):
        for state in ("CONFLICTING", "UNKNOWN", ""):
            data = posthog_ready()
            data["pr"]["mergeable"] = state
            self.assert_refused(data, "not MERGEABLE")

    def test_red_or_pending_check_is_refused(self):
        for bucket in ("fail", "pending", "cancel", ""):
            data = posthog_ready()
            data["pr"]["checks"].append({"name": "build", "state": "X", "bucket": bucket})
            self.assert_refused(data, "check build is")

    def test_pending_bot_review_request_is_refused_in_posthog_repos(self):
        data = posthog_ready()
        data["pr"]["review_requests"] = [{"login": "Copilot", "type": "Bot"}]
        self.assert_refused(data, "requested from Copilot has not arrived")

    def test_pending_team_request_does_not_block_posthog_repos(self):
        data = posthog_ready()
        data["pr"]["review_requests"] = [{"login": "team-flags", "type": "Team"}]
        self.assert_merges(data)

    def test_no_checks_is_not_red(self):
        data = posthog_ready()
        data["pr"]["checks"] = []
        self.assert_merges(data)

    def test_review_required_or_changes_requested_decision_is_refused(self):
        for decision in ("REVIEW_REQUIRED", "CHANGES_REQUESTED"):
            data = posthog_ready()
            data["pr"]["review_decision"] = decision
            self.assert_refused(data, "review decision")

    def test_outstanding_changes_requested_is_refused_even_without_required_reviews(self):
        data = posthog_ready()
        data["pr"]["review_decision"] = ""
        data["reviews"].append(review("alice", "CHANGES_REQUESTED", OLD, "2026-11-04T09:00:00Z"))
        self.assert_refused(data, "alice requested changes")

    def test_later_approval_clears_changes_requested(self):
        data = posthog_ready()
        data["reviews"].append(review("alice", "CHANGES_REQUESTED", OLD, "2026-11-04T09:00:00Z"))
        data["reviews"].append(review("alice", "APPROVED", HEAD, LATER))
        self.assert_merges(data)

    def test_commented_review_does_not_clear_changes_requested(self):
        data = posthog_ready()
        data["reviews"].append(review("alice", "CHANGES_REQUESTED", OLD, "2026-11-04T09:00:00Z"))
        data["reviews"].append(review("alice", "COMMENTED", OLD, "2026-11-04T09:30:00Z"))
        self.assert_refused(data, "alice requested changes")

    def test_unresolved_human_thread_is_refused(self):
        data = posthog_ready()
        data["threads"].append(thread(False, ALICE))
        self.assert_refused(data, "from alice is unresolved")

    def test_unresolved_thread_from_deleted_user_is_refused(self):
        data = posthog_ready()
        data["threads"].append(thread(False, {"login": "", "type": ""}))
        self.assert_refused(data, "a deleted user")

    def test_human_reply_in_unresolved_bot_thread_is_refused(self):
        data = posthog_ready()
        data["threads"].append(thread(False, COPILOT, ALICE))
        self.assert_refused(data, "from alice is unresolved")

    def test_human_reply_in_resolved_bot_thread_is_refused(self):
        data = posthog_ready()
        data["threads"].append(thread(True, COPILOT, ALICE, AUTHOR))
        self.assert_refused(data, "replied in a bot's review thread that was resolved")

    def test_unresolved_author_only_thread_passes(self):
        data = posthog_ready()
        data["threads"].append(thread(False, AUTHOR))
        self.assert_merges(data)

    def test_unresolved_bot_thread_and_resolved_human_thread_pass(self):
        data = posthog_ready()
        data["threads"].append(thread(False, COPILOT, AUTHOR))
        data["threads"].append(thread(True, ALICE, AUTHOR))
        self.assert_merges(data)

    def test_pr_against_a_non_default_branch_is_refused(self):
        data = posthog_ready()
        data["pr"]["base"] = "haacked/parent"
        self.assert_refused(data, "not the default branch main")

    def test_human_conversation_comment_before_addressing_is_refused(self):
        data = posthog_ready()
        data["issue_comments"].append({"login": "bob", "type": "User", "body": "don't merge yet", "created_at": "2026-11-04T10:59:00Z", "updated_at": "2026-11-04T10:59:00Z"})
        verdict = self.assert_refused(data, "bob commented on the PR")
        self.assertFalse(verdict["address_again"])

    def test_human_commented_review_body_is_refused(self):
        data = posthog_ready()
        data["reviews"].append(review("alice", "COMMENTED", OLD, "2026-11-04T10:30:00Z", body="Please hold"))
        self.assert_refused(data, "alice left a review comment that address-pr-reviews does not read")

    def test_human_commented_review_without_body_passes(self):
        data = posthog_ready()
        data["reviews"].append(review("alice", "COMMENTED", OLD, "2026-11-04T10:30:00Z", body=" "))
        self.assert_merges(data)

    def test_missing_addressed_time_is_refused(self):
        verdict = self.assert_refused(posthog_ready(), "does not record when reviews were addressed", addressed=None)
        self.assertTrue(verdict["address_again"])

    def test_review_after_addressing_is_refused(self):
        data = posthog_ready()
        data["reviews"].append(review("copilot-pull-request-reviewer[bot]", "COMMENTED", HEAD, LATER, "Bot"))
        verdict = self.assert_refused(data, "after reviews were addressed")
        self.assertTrue(verdict["address_again"])

    def test_refusal_without_late_feedback_does_not_address_again(self):
        data = posthog_ready()
        data["pr"]["is_draft"] = True
        self.assertFalse(self.assert_refused(data, "draft")["address_again"])

    def test_review_comment_after_addressing_is_refused(self):
        data = posthog_ready()
        data["review_comments"].append({"login": "greptile[bot]", "type": "Bot", "created_at": LATER})
        self.assertTrue(self.assert_refused(data, "left a review comment at")["address_again"])

    def test_author_and_bot_conversation_comments_after_addressing_pass(self):
        data = posthog_ready()
        data["issue_comments"].append({"login": "haacked", "type": "User", "body": "/trunk merge", "created_at": LATER, "updated_at": LATER})
        data["issue_comments"].append({"login": "trunk-io[bot]", "type": "Bot", "body": "queued", "created_at": LATER, "updated_at": LATER})
        data["review_comments"].append({"login": "haacked", "type": "User", "created_at": LATER})
        data["reviews"].append(review("haacked", "COMMENTED", HEAD, LATER))
        self.assert_merges(data)

    def test_review_comment_before_addressing_passes(self):
        data = posthog_ready()
        data["review_comments"].append({"login": "alice", "type": "User", "created_at": "2026-11-04T10:30:00Z"})
        self.assert_merges(data)

    def test_unknown_owner_is_refused(self):
        data = posthog_ready()
        data["repo"]["owner"] = "someone-else"
        self.assert_refused(data, "only in PostHog and haacked")

    def test_merge_method_falls_back_to_an_allowed_method(self):
        data = posthog_ready()
        data["repo"]["default_merge_method"] = "REBASE"
        data["repo"]["allowed_merge_methods"] = ["MERGE"]
        self.assertEqual(self.assert_merges(data)["method"], "merge")

    def test_no_allowed_merge_method_is_refused(self):
        data = posthog_ready()
        data["repo"]["allowed_merge_methods"] = []
        self.assert_refused(data, "allows no merge method")


class PostHogPolicyTest(MergeGateTest):
    def test_no_approval_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review()]
        self.assert_refused(data, "neither stamphog nor a human")

    def test_stamphog_approval_on_old_head_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(), stamphog(commit=OLD)]
        self.assert_refused(data, "neither stamphog nor a human")

    def test_stamphog_non_approval_after_approval_at_head_is_refused(self):
        data = posthog_ready()
        data["reviews"].append(stamphog("COMMENTED", at="2026-11-04T12:30:00Z"))
        verdict = self.assert_refused(data, "neither stamphog nor a human")
        self.assertFalse(verdict["address_again"], verdict["reasons"])

    def test_stamphog_login_from_a_user_is_not_stamphog(self):
        reviews = [review("stamphog[bot]", "APPROVED", HEAD, LATER, "User")]
        self.assertFalse(merge_gate.stamphog_approved(reviews, HEAD))

    def test_human_approval_at_head_counts(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(), review("alice", "APPROVED")]
        self.assertEqual(self.assert_merges(data)["approved_by"], ["alice"])

    def test_human_approval_on_old_head_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(), review("alice", "APPROVED", OLD)]
        self.assert_refused(data, "neither stamphog nor a human")

    def test_dismissed_human_approval_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(), review("alice", "DISMISSED")]
        self.assert_refused(data, "neither stamphog nor a human")

    def test_approval_from_outside_the_repository_does_not_count(self):
        for association in ("CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "NONE", ""):
            with self.subTest(association=association):
                data = posthog_ready()
                data["pr"]["review_decision"] = ""
                data["reviews"] = [reviewhog_review(), review("mallory", "APPROVED", association=association)]
                self.assert_refused(data, "neither stamphog nor a human")

    def test_collaborator_and_owner_approvals_count(self):
        for association in ("COLLABORATOR", "OWNER"):
            with self.subTest(association=association):
                data = posthog_ready()
                data["reviews"] = [reviewhog_review(), review("alice", "APPROVED", association=association)]
                self.assertEqual(self.assert_merges(data)["approved_by"], ["alice"])

    def test_other_bot_approval_does_not_count(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(), review("some-app[bot]", "APPROVED", kind="Bot")]
        self.assert_refused(data, "neither stamphog nor a human")

    def test_reviewhog_never_requested_is_refused(self):
        data = posthog_ready()
        data["timeline"] = []
        self.assertFalse(self.assert_refused(data, "no ReviewHog round was requested")["address_again"])

    def test_reviewhog_round_without_completion_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        self.assertTrue(self.assert_refused(data, "has not finished")["address_again"])

    def test_reviewhog_review_from_before_latest_label_is_refused(self):
        data = posthog_ready()
        data["timeline"].append({"event": "labeled", "label": "posthog-review", "created_at": "2026-11-04T10:10:00Z"})
        self.assert_refused(data, "has not finished")

    def test_unmarked_posthog_bot_review_does_not_finish_round(self):
        data = posthog_ready()
        data["reviews"] = [review("posthog[bot]", "COMMENTED", OLD, REVIEWHOG_DONE, "Bot", "quoting a report"), stamphog()]
        self.assert_refused(data, "has not finished")

    def test_finished_status_comment_completes_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 --> done", "created_at": LABELED, "updated_at": REVIEWHOG_DONE})
        self.assert_merges(data)

    def test_status_comment_still_reviewing_does_not_complete_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 --> ReviewHog is reviewing", "created_at": LABELED, "updated_at": REVIEWHOG_DONE})
        self.assert_refused(data, "has not finished")

    def test_fresh_status_placeholder_does_not_complete_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 -->", "created_at": REVIEWHOG_DONE, "updated_at": REVIEWHOG_DONE})
        self.assert_refused(data, "has not finished")

    def test_reviewhog_finishing_after_addressing_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 --> done", "created_at": LABELED, "updated_at": LATER})
        self.assertTrue(self.assert_refused(data, "the ReviewHog round finished at")["address_again"])

    def test_reviewhog_not_required_when_skipped(self):
        data = posthog_ready()
        data["timeline"] = []
        data["reviews"] = [stamphog()]
        self.assert_merges(data, reviewhog=False)


class HaackedPolicyTest(MergeGateTest):
    def test_no_configured_reviewers_merges(self):
        verdict = self.assert_merges(haacked_ready())
        self.assertEqual(verdict["policy"], "haacked")

    def test_pending_requested_reviewer_is_refused(self):
        data = haacked_ready()
        data["pr"]["review_requests"] = [{"login": "Copilot", "type": "Bot"}]
        self.assert_refused(data, "has not arrived")

    def test_pending_team_request_is_refused(self):
        data = haacked_ready()
        data["pr"]["review_requests"] = [{"login": "reviewers", "type": "Team"}]
        self.assert_refused(data, "has not arrived")

    def test_requested_bot_that_reviewed_passes(self):
        data = haacked_ready()
        data["timeline"].append(requested("Copilot", "Bot"))
        data["reviews"].append(review("copilot-pull-request-reviewer[bot]", "COMMENTED", OLD, "2026-11-04T10:30:00Z", "Bot"))
        self.assert_merges(data)

    def test_bot_requested_again_after_reviewing_is_refused(self):
        data = haacked_ready()
        data["timeline"].append(requested("Copilot", "Bot"))
        data["reviews"].append(review("copilot-pull-request-reviewer[bot]", "COMMENTED", OLD, "2026-11-04T10:30:00Z", "Bot"))
        data["timeline"].append(requested("Copilot", "Bot", at="2026-11-04T10:45:00Z"))
        data["pr"]["review_requests"] = [{"login": "copilot-pull-request-reviewer", "type": "Bot"}]
        self.assert_refused(data, "requested from copilot-pull-request-reviewer has not arrived")

    def test_requested_bot_that_never_reviewed_is_refused(self):
        data = haacked_ready()
        data["timeline"].append(requested("greptile-apps[bot]", "Bot"))
        self.assert_refused(data, "never reviewed")

    def test_removed_request_is_not_required(self):
        data = haacked_ready()
        data["timeline"].append(requested("alice"))
        data["timeline"].append(requested("alice", at="2026-11-04T10:01:00Z", event="review_request_removed"))
        self.assert_merges(data)

    def test_requested_human_must_approve_head(self):
        data = haacked_ready()
        data["timeline"].append(requested("alice"))
        self.assert_refused(data, "alice was requested and has not approved")
        data["reviews"].append(review("alice", "APPROVED", OLD))
        self.assert_refused(data, "alice was requested and has not approved")
        data["reviews"].append(review("alice", "APPROVED", HEAD, "2026-11-04T12:30:00Z"))
        self.assert_merges(data)

    def test_requested_human_comment_review_is_refused(self):
        data = haacked_ready()
        data["timeline"].append(requested("alice"))
        data["reviews"].append(review("alice", "COMMENTED", HEAD, "2026-11-04T10:30:00Z"))
        self.assert_refused(data, "alice was requested and has not approved")

    def test_outside_approval_does_not_satisfy_requested_reviewer_or_github_approval(self):
        data = haacked_ready()
        data["pr"]["review_decision"] = "APPROVED"
        data["timeline"].append(requested("alice"))
        data["reviews"].append(review("alice", "APPROVED", association="NONE"))
        self.assert_refused(data, "alice was requested and has not approved")
        self.assert_refused(data, "no reviewer approved")

    def test_github_approval_without_approval_at_head_is_refused(self):
        data = haacked_ready()
        data["pr"]["review_decision"] = "APPROVED"
        data["reviews"].append(review("alice", "APPROVED", OLD, "2026-11-04T10:30:00Z"))
        self.assert_refused(data, "no reviewer approved")

    def test_required_review_missing_is_refused(self):
        data = haacked_ready()
        data["pr"]["review_decision"] = "REVIEW_REQUIRED"
        self.assert_refused(data, "REVIEW_REQUIRED")


ROLLUP = [
    {"__typename": "CheckRun", "name": "tests", "workflowName": "CI", "status": "COMPLETED", "conclusion": "FAILURE", "startedAt": "2026-11-04T09:00:00Z"},
    {"__typename": "CheckRun", "name": "tests", "workflowName": "CI", "status": "COMPLETED", "conclusion": "SUCCESS", "startedAt": "2026-11-04T09:30:00Z"},
    {"__typename": "CheckRun", "name": "slow", "workflowName": "CI", "status": "IN_PROGRESS", "conclusion": "", "startedAt": "2026-11-04T09:00:00Z"},
    {"__typename": "StatusContext", "context": "ci/legacy", "state": "PENDING", "startedAt": "2026-11-04T09:00:00Z"},
]


def raw_gh_output(rollup=ROLLUP):
    return {
        "pr": {
            "number": 7,
            "url": "https://github.com/haacked/dotfiles/pull/7",
            "state": "OPEN",
            "isDraft": False,
            "headRefOid": HEAD,
            "baseRefName": "main",
            "author": {"login": "haacked"},
            "reviewDecision": "",
            "mergeable": "MERGEABLE",
            "statusCheckRollup": rollup,
        },
        "checks": merge_gate.checks_rollup(rollup),
        "repo": {"owner": {"login": "haacked"}, "name": "dotfiles", "defaultBranchRef": {"name": "main"}, "viewerDefaultMergeMethod": "MERGE", "mergeCommitAllowed": True, "squashMergeAllowed": False, "rebaseMergeAllowed": True},
        "reviews": [{"user": {"login": "alice", "type": "User"}, "author_association": "MEMBER", "state": "APPROVED", "commit_id": HEAD, "submitted_at": LATER, "body": ""}],
        "review_comments": [{"user": None, "created_at": LATER}],
        "issue_comments": [{"user": {"login": "posthog[bot]", "type": "Bot"}, "body": "x", "created_at": LABELED, "updated_at": LATER}],
        "timeline": [
            {"event": "labeled", "label": {"name": "posthog-review"}, "created_at": LABELED},
            {"event": "review_requested", "requested_reviewer": {"login": "alice", "type": "User"}, "created_at": LABELED},
            {"event": "review_requested", "requested_team": {"slug": "core"}, "created_at": LABELED},
            {"event": "committed"},
        ],
        "threads": [
            {"data": {"repository": {"pullRequest": {
                "reviewRequests": {"nodes": [
                    {"requestedReviewer": {"__typename": "Team", "slug": "core"}},
                    {"requestedReviewer": {"__typename": "Bot", "login": "copilot-pull-request-reviewer"}},
                ]},
                "reviewThreads": {"nodes": [
                {"isResolved": False, "comments": {"nodes": [
                    {"url": "u1", "author": {"login": "copilot-pull-request-reviewer", "__typename": "Bot"}},
                    {"url": "u1r", "author": {"login": "alice", "__typename": "User"}},
                ]}},
                {"isResolved": True, "comments": {"nodes": [{"url": "u2", "author": None}]}},
            ]},
            }}}},
        ],
    }


class NormalizeTest(unittest.TestCase):
    def test_normalize_shapes(self):
        data = merge_gate.normalize(raw_gh_output())
        self.assertEqual(data["repo"]["owner"], "haacked")
        self.assertEqual(data["repo"]["default_branch"], "main")
        self.assertEqual(data["pr"]["base"], "main")
        self.assertEqual(data["repo"]["allowed_merge_methods"], ["MERGE", "REBASE"])
        self.assertEqual(
            sorted(data["pr"]["checks"], key=lambda c: c["name"]),
            [
                {"name": "ci/legacy", "state": "PENDING", "bucket": "pending"},
                {"name": "slow", "state": "IN_PROGRESS", "bucket": "pending"},
                {"name": "tests", "state": "SUCCESS", "bucket": "pass"},
            ],
        )
        self.assertEqual(data["pr"]["review_requests"], [{"login": "core", "type": "Team"}, {"login": "copilot-pull-request-reviewer", "type": "Bot"}])
        self.assertEqual(data["review_comments"], [{"login": "", "type": "", "created_at": LATER}])
        self.assertEqual(data["reviews"], [{"login": "alice", "type": "User", "state": "APPROVED", "commit_id": HEAD, "submitted_at": LATER, "body": "", "association": "MEMBER"}])
        self.assertEqual(data["issue_comments"], [{"login": "posthog[bot]", "type": "Bot", "body": "x", "created_at": LABELED, "updated_at": LATER}])
        self.assertEqual([e["event"] for e in data["timeline"]], ["labeled", "review_requested"])
        self.assertEqual(data["timeline"][1]["reviewer"], {"login": "alice", "type": "User"})
        self.assertEqual(
            data["threads"],
            [
                {"resolved": False, "authors": [{"login": "copilot-pull-request-reviewer", "type": "Bot"}, {"login": "alice", "type": "User"}], "url": "u1"},
                {"resolved": True, "authors": [{"login": "", "type": ""}], "url": "u2"},
            ],
        )

    def test_rerun_green_check_replaces_its_failed_run(self):
        data = merge_gate.normalize(raw_gh_output(ROLLUP[:2]))
        self.assertEqual(data["pr"]["checks"], [{"name": "tests", "state": "SUCCESS", "bucket": "pass"}])

    def test_empty_rollup_has_no_checks(self):
        self.assertEqual(merge_gate.checks_rollup(None), [])

    def test_normalized_pending_checks_refuse(self):
        data = merge_gate.normalize(raw_gh_output())
        verdict = merge_gate.decide(data, HEAD, ADDRESSED, True)
        self.assertIn("check slow is IN_PROGRESS", verdict["reasons"])
        self.assertIn("check ci/legacy is PENDING", verdict["reasons"])


def mergeable_raw():
    raw = raw_gh_output(ROLLUP[:2])
    raw["threads"] = []
    raw["timeline"] = []
    raw["review_comments"] = []
    return raw


def posthog_without_reviewhog_raw():
    raw = mergeable_raw()
    raw["pr"]["url"] = "https://github.com/PostHog/posthog/pull/7"
    raw["repo"]["owner"] = {"login": "PostHog"}
    raw["issue_comments"] = []
    return raw


class MainTest(unittest.TestCase):
    def run_main(self, argv, fetched=(), error=None):
        out = io.StringIO()
        pages = list(fetched)
        self.sleeps = []

        def fake_fetch(_pr):
            if error:
                raise merge_gate.GateError(error)
            return pages.pop(0)

        with mock.patch.object(merge_gate, "fetch", fake_fetch), mock.patch.object(merge_gate.time, "sleep", self.sleeps.append), mock.patch("sys.stdout", out):
            code = merge_gate.main(argv)
        return code, json.loads(out.getvalue())

    def test_refusal_exits_3(self):
        code, verdict = self.run_main(["--head", HEAD, "--addressed-at", ADDRESSED], [raw_gh_output()])
        self.assertEqual(code, 3)
        self.assertFalse(verdict["merge"])

    def test_merge_exits_0(self):
        raw = mergeable_raw()
        code, verdict = self.run_main(["--head", HEAD, "--addressed-at", ADDRESSED], [raw])
        self.assertEqual(code, 0, verdict)
        self.assertEqual(verdict["method"], "merge")

    def test_no_reviewhog_flag_drops_the_reviewhog_requirement(self):
        argv = ["--head", HEAD, "--addressed-at", ADDRESSED]
        code, verdict = self.run_main([*argv, "--no-reviewhog"], [posthog_without_reviewhog_raw()])
        self.assertEqual(code, 0, verdict)
        code, verdict = self.run_main(argv, [posthog_without_reviewhog_raw()])
        self.assertEqual(code, 3)
        self.assertIn("no ReviewHog round was requested on this PR", verdict["reasons"])

    def test_unknown_mergeability_is_read_again_once(self):
        unknown = mergeable_raw()
        unknown["pr"]["mergeable"] = "UNKNOWN"
        code, verdict = self.run_main(["--head", HEAD, "--addressed-at", ADDRESSED], [unknown, mergeable_raw()])
        self.assertEqual(code, 0, verdict)
        self.assertEqual(self.sleeps, [merge_gate.MERGEABILITY_RETRY_SECONDS])

    def test_unknown_mergeability_twice_is_refused(self):
        unknown = mergeable_raw()
        unknown["pr"]["mergeable"] = "UNKNOWN"
        code, verdict = self.run_main(["--head", HEAD, "--addressed-at", ADDRESSED], [unknown, unknown])
        self.assertEqual(code, 3)
        self.assertIn("GitHub reports the PR as UNKNOWN, not MERGEABLE", verdict["reasons"])

    def test_fetch_failure_exits_1(self):
        code, verdict = self.run_main(["--head", HEAD], error="gh pr view failed")
        self.assertEqual(code, 1)
        self.assertEqual(verdict, {"merge": False, "error": "gh pr view failed"})

    def test_malformed_addressed_time_is_rejected(self):
        with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit) as raised:
            merge_gate.main(["--head", HEAD, "--addressed-at", "2026-11-04 11:00"])
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
