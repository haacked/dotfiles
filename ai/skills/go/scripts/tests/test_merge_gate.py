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
REQUESTED = "2026-11-04T10:00:00Z"
REVIEWHOG_DONE = "2026-11-04T10:05:00Z"
ADDRESSED = "2026-11-04T11:00:00Z"
LATER = "2026-11-04T12:00:00Z"


def review(login, state, commit=HEAD, at=LATER, kind="User", body="", association="MEMBER", edited=None):
    return {"login": login, "type": kind, "state": state, "commit_id": commit, "submitted_at": at, "body_changed_at": max(at, edited or "") if at else None, "body": body, "association": association}


def stamphog(state="APPROVED", commit=HEAD, at=LATER):
    return review("stamphog[bot]", state, commit, at, "Bot", "**Approved.**")


def reviewhog_review(at=REVIEWHOG_DONE, mode="full"):
    return review("posthog[bot]", "COMMENTED", OLD, at, "Bot", f"**PostHog Review** <!-- reviewhog:published:1:{OLD}:{mode} -->")


def trigger(body="@posthog review --deep", at=REQUESTED, login="haacked", kind="User"):
    return {"login": login, "type": kind, "body": body, "created_at": at, "updated_at": at}


ALICE = {"login": "alice", "type": "User"}
AUTHOR = {"login": "haacked", "type": "User"}
COPILOT = {"login": "copilot-pull-request-reviewer", "type": "Bot"}


def thread(resolved, *authors):
    return {"resolved": resolved, "authors": list(authors), "url": "u1"}


def requested(login, kind="User", at=REQUESTED, event="review_requested"):
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
            "code_owners": [],
            "code_owners_pending": [],
        },
        "reviews": [],
        "review_comments": [],
        "issue_comments": [],
        "timeline": [],
        "threads": [],
    }


def posthog_ready():
    data = base_data()
    data["issue_comments"].append(trigger())
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

    def test_pr_without_code_owners_still_needs_stamphog_or_a_person(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(), stamphog("DISMISSED")]
        verdict = self.assert_refused(data, "neither stamphog nor a human")
        self.assertFalse(any("code-owner" in reason for reason in verdict["reasons"]), verdict["reasons"])

    def test_reviewhog_never_requested_is_refused(self):
        data = posthog_ready()
        data["issue_comments"] = []
        self.assertFalse(self.assert_refused(data, "no ReviewHog round was requested")["address_again"])

    def test_reviewhog_round_without_completion_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        self.assertTrue(self.assert_refused(data, "has not finished")["address_again"])

    def test_reviewhog_review_from_before_latest_request_is_refused(self):
        data = posthog_ready()
        data["issue_comments"].append(trigger(at="2026-11-04T10:10:00Z"))
        self.assert_refused(data, "has not finished")

    def test_standard_review_does_not_finish_deep_request(self):
        data = posthog_ready()
        data["reviews"] = [reviewhog_review(mode="flash"), stamphog()]
        self.assert_refused(data, "has not finished")

    def test_standard_review_finishes_plain_request(self):
        data = posthog_ready()
        data["issue_comments"] = [trigger("@posthog review")]
        data["reviews"] = [reviewhog_review(mode="flash"), stamphog()]
        self.assert_merges(data)

    def before_request(self, body, review_body, login="posthog[bot]", commit=HEAD):
        data = posthog_ready()
        data["issue_comments"] = [trigger(body, at=REVIEWHOG_DONE)]
        data["reviews"] = [review(login, "COMMENTED", commit, REQUESTED, "Bot", review_body), stamphog()]
        return data

    def test_standard_review_of_head_before_plain_request_finishes_it(self):
        self.assert_merges(self.before_request("@posthog review", f"<!-- reviewhog:published:1:{HEAD}:flash -->"))

    def test_standard_review_of_older_head_before_plain_request_is_refused(self):
        self.assert_refused(self.before_request("@posthog review", f"<!-- reviewhog:published:1:{OLD}:flash -->", commit=OLD), "has not finished")

    def test_deep_review_of_head_before_plain_request_finishes_it(self):
        self.assert_merges(self.before_request("@posthog review", f"<!-- reviewhog:published:1:{HEAD}:full -->"))

    def test_deep_review_of_head_before_deep_request_finishes_it(self):
        self.assert_merges(self.before_request("@posthog review --deep", f"<!-- reviewhog:published:1:{HEAD}:full -->"))

    def test_standard_review_of_head_before_deep_request_is_refused(self):
        self.assert_refused(self.before_request("@posthog review --deep", f"<!-- reviewhog:published:1:{HEAD}:flash -->"), "has not finished")

    def test_clean_reply_on_head_before_plain_request_is_refused(self):
        # ReviewHog runs a requested round again at that head, and the round can publish findings later.
        self.assert_refused(self.before_request("@posthog review", f"No findings. <!-- reviewhog:clean-reply:1:{HEAD} -->"), "has not finished")

    def test_large_pr_note_on_head_before_plain_request_is_refused(self):
        self.assert_refused(self.before_request("@posthog review", f"<!-- reviewhog:large-pr-note:1:{HEAD} -->"), "has not finished")

    def test_other_bot_quoting_marker_on_head_does_not_finish_request(self):
        data = self.before_request("@posthog review", f"<!-- reviewhog:published:1:{HEAD}:flash -->", login="copilot-pull-request-reviewer[bot]")
        self.assert_refused(data, "has not finished")

    def test_mid_sentence_mention_is_not_a_request(self):
        data = posthog_ready()
        data["issue_comments"] = [trigger("should we ask @posthog review --deep?")]
        self.assert_refused(data, "no ReviewHog round was requested")

    def test_bot_comment_is_not_a_request(self):
        data = posthog_ready()
        data["issue_comments"] = [trigger(login="posthog[bot]", kind="Bot")]
        self.assert_refused(data, "no ReviewHog round was requested")

    def test_unmarked_posthog_bot_review_does_not_finish_round(self):
        data = posthog_ready()
        data["reviews"] = [review("posthog[bot]", "COMMENTED", OLD, REVIEWHOG_DONE, "Bot", "quoting a report"), stamphog()]
        self.assert_refused(data, "has not finished")

    def test_finished_status_comment_completes_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 --> done", "created_at": REQUESTED, "updated_at": REVIEWHOG_DONE})
        self.assert_merges(data)

    def test_status_comment_still_reviewing_does_not_complete_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 --> ReviewHog is reviewing", "created_at": REQUESTED, "updated_at": REVIEWHOG_DONE})
        self.assert_refused(data, "has not finished")

    def test_status_comment_after_progress_edit_does_not_complete_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        body = "<!-- reviewhog:status:1 -->\n### PostHog Review · Deep · reviewing `eb71424`\n\n| Step | Status | Result |"
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": body, "created_at": REQUESTED, "updated_at": REVIEWHOG_DONE})
        self.assert_refused(data, "has not finished")

    def test_teammate_trigger_comment_does_not_block_merge(self):
        data = posthog_ready()
        data["issue_comments"] = [trigger(login="alice")]
        self.assert_merges(data)

    def test_fresh_status_placeholder_does_not_complete_round(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 -->", "created_at": REVIEWHOG_DONE, "updated_at": REVIEWHOG_DONE})
        self.assert_refused(data, "has not finished")

    def test_reviewhog_finishing_after_addressing_is_refused(self):
        data = posthog_ready()
        data["reviews"] = [stamphog()]
        data["issue_comments"].append({"login": "posthog[bot]", "type": "Bot", "body": "<!-- reviewhog:status:1 --> done", "created_at": REQUESTED, "updated_at": LATER})
        self.assertTrue(self.assert_refused(data, "the ReviewHog round finished at")["address_again"])

    def test_reviewhog_not_required_when_skipped(self):
        data = posthog_ready()
        data["issue_comments"] = []
        data["reviews"] = [stamphog()]
        self.assert_merges(data, reviewhog=False)


def code_owner_gated():
    data = posthog_ready()
    data["pr"]["code_owners"] = ["PostHog/hogql"]
    data["pr"]["code_owners_pending"] = ["PostHog/hogql"]
    data["pr"]["review_requests"] = [{"login": "hogql", "type": "Team"}]
    data["pr"]["review_decision"] = "REVIEW_REQUIRED"
    return data


class CodeOwnerTest(MergeGateTest):
    def test_stamphog_approval_does_not_merge_a_code_owner_gated_pr(self):
        verdict = self.assert_refused(code_owner_gated(), "waiting on code-owner review from @PostHog/hogql")
        self.assertFalse(any("stamphog" in reason for reason in verdict["reasons"]), verdict["reasons"])
        self.assertEqual(verdict["approved_by"], [])

    def test_code_owner_approval_merges_without_stamphog(self):
        data = code_owner_gated()
        data["pr"]["review_requests"] = []
        data["pr"]["review_decision"] = "APPROVED"
        data["reviews"] = [reviewhog_review(), review("hogql-member", "APPROVED")]
        self.assertEqual(self.assert_merges(data)["approved_by"], ["hogql-member"])

    def test_dismissed_stamphog_approval_is_not_a_reason(self):
        data = code_owner_gated()
        data["pr"]["review_decision"] = "APPROVED"
        data["reviews"] = [reviewhog_review(), stamphog("DISMISSED")]
        verdict = self.assert_refused(data, "no person approved")
        self.assertFalse(any("stamphog" in reason for reason in verdict["reasons"]), verdict["reasons"])

    def test_github_approval_without_a_person_at_head_is_refused(self):
        data = code_owner_gated()
        data["pr"]["review_decision"] = "APPROVED"
        data["reviews"] = [reviewhog_review(), stamphog(), review("hogql-member", "APPROVED", OLD)]
        verdict = self.assert_refused(data, "no person approved")
        self.assertEqual(verdict["approved_by"], [])

    def test_code_owner_person_is_named_in_the_reason(self):
        data = code_owner_gated()
        data["pr"]["code_owners"] = ["cvolzer3"]
        data["pr"]["code_owners_pending"] = ["cvolzer3"]
        self.assert_refused(data, "waiting on code-owner review from @cvolzer3")

    def test_owner_who_already_reviewed_is_not_waited_on(self):
        data = code_owner_gated()
        data["pr"]["code_owners"] = ["PostHog/hogql", "PostHog/team-frontend"]
        verdict = self.assert_refused(data, "waiting on code-owner review from @PostHog/hogql")
        self.assertFalse(any("waiting on code-owner review from @PostHog/hogql, @PostHog/team-frontend" in reason for reason in verdict["reasons"]), verdict["reasons"])

    def test_owner_who_reviewed_without_approving_is_waited_on(self):
        data = code_owner_gated()
        data["pr"]["code_owners_pending"] = []
        self.assert_refused(data, "waiting on code-owner review from @PostHog/hogql")

    def test_changes_requested_does_not_say_waiting_on_code_owners(self):
        data = code_owner_gated()
        data["pr"]["review_decision"] = "CHANGES_REQUESTED"
        verdict = self.assert_refused(data, "GitHub's review decision is CHANGES_REQUESTED")
        self.assertFalse(any("waiting on code-owner review" in reason for reason in verdict["reasons"]), verdict["reasons"])

    def test_person_approval_without_github_approval_is_refused(self):
        data = code_owner_gated()
        data["reviews"] = [reviewhog_review(), review("alice", "APPROVED")]
        self.assert_refused(data, "waiting on code-owner review from @PostHog/hogql")


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


COMMENTED_AT = "2026-11-04T10:30:00Z"
AFTER_APPROVAL = "2026-11-04T12:30:00Z"


def conversation_comment(login, created=COMMENTED_AT, updated=None, kind="User"):
    return {"login": login, "type": kind, "body": "nice!", "created_at": created, "updated_at": updated or created}


class UnreadCommentTest(MergeGateTest):
    """A person's later approval at the head clears the review body and conversation comments they left earlier."""

    def commented(self, *reviews, comments=()):
        data = posthog_ready()
        data["reviews"] += list(reviews)
        data["issue_comments"] += list(comments)
        return data

    def test_later_approval_at_head_clears_review_body_and_conversation_comment(self):
        data = self.commented(
            review("alice", "COMMENTED", OLD, COMMENTED_AT, body="Please hold"),
            review("alice", "APPROVED", HEAD, LATER),
            comments=[conversation_comment("alice")],
        )
        verdict = self.assert_merges(data)
        self.assertFalse(verdict["manual_merge"])

    def test_approval_login_matches_case_insensitively(self):
        data = self.commented(review("Alice", "APPROVED", HEAD, LATER), comments=[conversation_comment("alice")])
        self.assert_merges(data)

    def test_approval_on_an_older_head_does_not_clear(self):
        data = self.commented(review("alice", "APPROVED", OLD, LATER), comments=[conversation_comment("alice")])
        self.assert_refused(data, "alice commented on the PR")

    def test_approval_from_outside_the_repository_does_not_clear(self):
        for association in ("CONTRIBUTOR", "FIRST_TIME_CONTRIBUTOR", "NONE", ""):
            with self.subTest(association=association):
                data = self.commented(review("mallory", "APPROVED", HEAD, LATER, association=association), comments=[conversation_comment("mallory")])
                self.assert_refused(data, "mallory commented on the PR")

    def test_comment_after_the_approval_refuses(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), comments=[conversation_comment("alice", AFTER_APPROVAL)])
        self.assert_refused(data, "alice commented on the PR")

    def test_review_body_after_the_approval_refuses(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), review("alice", "COMMENTED", HEAD, AFTER_APPROVAL, body="one more thing"))
        self.assert_refused(data, "alice left a review comment")

    def test_comment_edited_after_the_approval_refuses(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), comments=[conversation_comment("alice", COMMENTED_AT, AFTER_APPROVAL)])
        self.assert_refused(data, "alice commented on the PR")

    def test_comment_at_the_same_second_as_the_approval_refuses(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), comments=[conversation_comment("alice", LATER)])
        self.assert_refused(data, "alice commented on the PR")

    def test_one_late_comment_keeps_every_comment_from_that_person(self):
        data = self.commented(
            review("alice", "APPROVED", HEAD, LATER),
            comments=[conversation_comment("alice"), conversation_comment("alice", AFTER_APPROVAL)],
        )
        verdict = self.assert_refused(data, f"alice commented on the PR at {COMMENTED_AT}")
        self.assertIn(f"alice commented on the PR at {AFTER_APPROVAL}", verdict["reasons"])

    def test_review_body_edited_after_the_approval_refuses(self):
        data = self.commented(review("alice", "COMMENTED", OLD, COMMENTED_AT, body="do not merge", edited=AFTER_APPROVAL), review("alice", "APPROVED", HEAD, LATER))
        self.assert_refused(data, "alice left a review comment")

    def test_review_without_a_known_edit_time_does_not_clear(self):
        commented = review("alice", "COMMENTED", OLD, COMMENTED_AT, body="hold")
        commented["body_changed_at"] = None
        data = self.commented(commented, review("alice", "APPROVED", HEAD, LATER))
        self.assert_refused(data, "alice left a review comment")

    def test_comment_without_a_time_does_not_clear(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), review("alice", "COMMENTED", OLD, None, body="hold"))
        self.assert_refused(data, "alice left a review comment")

    def test_changes_requested_after_the_approval_does_not_clear(self):
        data = self.commented(
            review("alice", "APPROVED", HEAD, "2026-11-04T11:30:00Z"),
            review("alice", "CHANGES_REQUESTED", HEAD, LATER),
            comments=[conversation_comment("alice")],
        )
        self.assert_refused(data, "alice commented on the PR")

    def test_another_persons_approval_does_not_clear(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), comments=[conversation_comment("bob")])
        self.assert_refused(data, "bob commented on the PR")

    def test_deleted_user_approval_does_not_clear_deleted_user_comment(self):
        for login in ("", "ghost"):
            with self.subTest(login=login):
                data = self.commented(review(login, "APPROVED", HEAD, LATER), comments=[conversation_comment(login)])
                self.assert_refused(data, "commented on the PR")

    def test_trigger_comment_after_the_approval_does_not_refuse(self):
        data = self.commented(review("alice", "APPROVED", HEAD, LATER), comments=[conversation_comment("alice"), trigger(at=AFTER_APPROVAL, login="alice")])
        self.assert_merges(data, reviewhog=False)

    def test_approval_clears_in_haacked_repositories(self):
        data = haacked_ready()
        data["reviews"] += [review("alice", "APPROVED", HEAD, LATER)]
        data["issue_comments"].append(conversation_comment("alice"))
        self.assert_merges(data)


class ManualMergeTest(MergeGateTest):
    def test_only_unread_comments_need_a_manual_merge(self):
        data = posthog_ready()
        data["reviews"].append(review("alice", "COMMENTED", OLD, COMMENTED_AT, body="Please hold"))
        data["issue_comments"].append(conversation_comment("bob"))
        verdict = self.assert_refused(data, "bob commented on the PR")
        self.assertTrue(verdict["manual_merge"])
        self.assertFalse(verdict["address_again"])

    def test_another_refusal_is_not_a_manual_merge(self):
        data = posthog_ready()
        data["issue_comments"].append(conversation_comment("bob"))
        data["pr"]["is_draft"] = True
        self.assertFalse(self.assert_refused(data, "draft")["manual_merge"])

    def test_feedback_to_address_is_not_a_manual_merge(self):
        data = posthog_ready()
        data["issue_comments"].append(conversation_comment("bob"))
        verdict = self.assert_refused(data, "does not record when reviews were addressed", addressed=None)
        self.assertFalse(verdict["manual_merge"])

    def test_other_refusals_are_not_a_manual_merge(self):
        self.assertFalse(self.assert_refused(base_data("haacked") | {"timeline": [requested("bob")]}, "bob was requested")["manual_merge"])

    def test_a_mergeable_pr_is_not_a_manual_merge(self):
        self.assertFalse(self.assert_merges(posthog_ready())["manual_merge"])


class SharedRulesTest(unittest.TestCase):
    def test_copilot_logins_come_from_the_shared_file(self):
        shared = json.loads((Path(__file__).resolve().parents[5] / "bin" / "lib" / "copilot-logins.json").read_text())
        self.assertEqual(merge_gate.COPILOT_LOGINS, set(shared))

    def test_reviewhog_round_comes_from_pending_reviews_jq(self):
        data = posthog_ready()
        data["issue_comments"].insert(0, conversation_comment("bob"))
        self.assertEqual(merge_gate.reviewhog_round(data), {"requested_at": REQUESTED, "completed_at": REVIEWHOG_DONE, "triggers": [1]})


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
        "reviews": [
            {"id": 1, "user": {"login": "alice", "type": "User"}, "author_association": "MEMBER", "state": "APPROVED", "commit_id": HEAD, "submitted_at": LATER, "body": ""},
            {"id": 2, "user": {"login": "bob", "type": "User"}, "author_association": "MEMBER", "state": "COMMENTED", "commit_id": OLD, "submitted_at": COMMENTED_AT, "body": "x"},
            {"id": 3, "user": {"login": "carol", "type": "User"}, "author_association": "MEMBER", "state": "COMMENTED", "commit_id": OLD, "submitted_at": COMMENTED_AT, "body": "x"},
        ],
        "review_edits": [{"data": {"repository": {"pullRequest": {"reviews": {"nodes": [
            {"databaseId": 1, "lastEditedAt": None},
            {"databaseId": 2, "lastEditedAt": AFTER_APPROVAL},
        ]}}}}}],
        "review_comments": [{"user": None, "created_at": LATER}],
        "issue_comments": [{"user": {"login": "posthog[bot]", "type": "Bot"}, "body": "x", "created_at": REQUESTED, "updated_at": LATER}],
        "timeline": [
            {"event": "labeled", "label": {"name": "posthog-review"}, "created_at": REQUESTED},
            {"event": "review_requested", "requested_reviewer": {"login": "alice", "type": "User"}, "created_at": REQUESTED},
            {"event": "review_requested", "requested_team": {"slug": "core"}, "created_at": REQUESTED},
            {"event": "committed"},
        ],
        "code_owners": ([{"data": {"repository": {
            "github": {"text": "posthog/hogql/** @PostHog/hogql\n"},
            "root": None,
            "docs": None,
            "pullRequest": {
                "author": {"login": "haacked"},
                "baseRef": {"branchProtectionRule": None},
                "reviewRequests": {"nodes": [{"asCodeOwner": True, "requestedReviewer": {"combinedSlug": "PostHog/hogql"}}]},
                "reviews": {"nodes": []},
            },
        }}}], [{"type": "pull_request", "parameters": {"require_code_owner_review": True}}]),
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
        self.assertEqual(data["pr"]["code_owners"], ["PostHog/hogql"])
        self.assertEqual(data["pr"]["code_owners_pending"], ["PostHog/hogql"])
        self.assertEqual(data["review_comments"], [{"login": "", "type": "", "created_at": LATER}])
        self.assertEqual(data["reviews"][0], {"login": "alice", "type": "User", "state": "APPROVED", "commit_id": HEAD, "submitted_at": LATER, "body_changed_at": LATER, "body": "", "association": "MEMBER"})
        self.assertEqual([r["body_changed_at"] for r in data["reviews"]], [LATER, AFTER_APPROVAL, None])
        self.assertEqual(data["issue_comments"], [{"login": "posthog[bot]", "type": "Bot", "body": "x", "created_at": REQUESTED, "updated_at": LATER}])
        self.assertEqual([e["event"] for e in data["timeline"]], ["review_requested"])
        self.assertEqual(data["timeline"][0]["reviewer"], {"login": "alice", "type": "User"})
        self.assertEqual(
            data["threads"],
            [
                {"resolved": False, "authors": [{"login": "copilot-pull-request-reviewer", "type": "Bot"}, {"login": "alice", "type": "User"}], "url": "u1"},
                {"resolved": True, "authors": [{"login": "", "type": ""}], "url": "u2"},
            ],
        )

    def test_code_owner_request_without_a_rule_requiring_it_is_not_a_code_owner(self):
        data = merge_gate.normalize(mergeable_raw())
        self.assertEqual(data["pr"]["code_owners"], [])

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
    raw["reviews"] = raw["reviews"][:1]
    raw["threads"] = []
    raw["timeline"] = []
    raw["review_comments"] = []
    raw["code_owners"] = (raw["code_owners"][0], [])
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

    def test_reviewhog_verdict_failure_exits_1(self):
        raw = mergeable_raw()
        raw["pr"]["url"] = "https://github.com/PostHog/posthog/pull/7"
        raw["repo"]["owner"] = {"login": "PostHog"}
        with mock.patch.object(merge_gate, "PENDING_REVIEWS_JQ", Path("/nonexistent/pending-reviews.jq")):
            code, verdict = self.run_main(["--head", HEAD, "--addressed-at", ADDRESSED], [raw])
        self.assertEqual(code, 1)
        self.assertFalse(verdict["merge"])
        self.assertIn("pending-reviews.jq failed", verdict["error"])

    def test_malformed_addressed_time_is_rejected(self):
        with mock.patch("sys.stderr", io.StringIO()), self.assertRaises(SystemExit) as raised:
            merge_gate.main(["--head", HEAD, "--addressed-at", "2026-11-04 11:00"])
        self.assertEqual(raised.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
