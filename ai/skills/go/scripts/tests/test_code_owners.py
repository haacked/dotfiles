import importlib.util
import io
import json
from pathlib import Path
import subprocess
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "code-owners.py"
SPEC = importlib.util.spec_from_file_location("code_owners", SCRIPT)
code_owners = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(code_owners)

CODEOWNERS = """# HogQL team owns HogQL changes
posthog/hogql/** @PostHog/hogql
posthog/hogql/database/schema/**
products/mobile/** @cvolzer3
frontend/** @PostHog/team-frontend # comment @PostHog/team-commented
"""

REQUIRED = [{"type": "pull_request", "parameters": {"require_code_owner_review": True}}]


def request(name, as_code_owner=True):
    key = "combinedSlug" if "/" in name else "login"
    return {"asCodeOwner": as_code_owner, "requestedReviewer": {key: name}}


def reviewed(login="someone", *teams):
    return {"author": {"login": login}, "onBehalfOf": {"nodes": [{"combinedSlug": team} for team in teams]}}


def page(requests=(), reviews=(), github=CODEOWNERS, root=None, docs=None, protection=None, author="haacked"):
    blob = lambda text: {"text": text} if text is not None else None
    return {"data": {"repository": {
        "github": blob(github),
        "root": blob(root),
        "docs": blob(docs),
        "pullRequest": {
            "author": {"login": author},
            "baseRef": {"branchProtectionRule": protection},
            "reviewRequests": {"nodes": list(requests)},
            "reviews": {"nodes": list(reviews)},
        },
    }}}


def owners(pages, rules=REQUIRED):
    return code_owners.owners(pages, rules)


class OwnersTest(unittest.TestCase):
    def test_open_code_owner_request_is_pending(self):
        result = owners([page([request("PostHog/hogql"), request("PostHog/team-data-tools", False)])])
        self.assertEqual(result, {"owners": ["PostHog/hogql"], "pending": ["PostHog/hogql"]})

    def test_open_code_owner_request_for_a_person_is_pending(self):
        result = owners([page([request("cvolzer3")])])
        self.assertEqual(result, {"owners": ["cvolzer3"], "pending": ["cvolzer3"]})

    def test_open_code_owner_request_counts_without_a_codeowners_file(self):
        self.assertEqual(owners([page([request("PostHog/hogql")], github=None)])["owners"], ["PostHog/hogql"])

    def test_review_on_behalf_of_a_named_team_counts_after_its_request_closes(self):
        result = owners([page(reviews=[reviewed("member", "PostHog/hogql")])])
        self.assertEqual(result, {"owners": ["PostHog/hogql"], "pending": []})

    def test_review_by_a_named_person_counts_after_their_request_closes(self):
        self.assertEqual(owners([page(reviews=[reviewed("CVolzer3")])])["owners"], ["CVolzer3"])

    def test_review_by_the_author_does_not_count(self):
        self.assertEqual(owners([page(reviews=[reviewed("cvolzer3")], author="cvolzer3")])["owners"], [])

    def test_review_on_behalf_of_a_team_codeowners_never_names_does_not_count(self):
        self.assertEqual(owners([page(reviews=[reviewed("member", "PostHog/team-feature-flags")])])["owners"], [])

    def test_owners_in_comments_are_not_named(self):
        result = owners([page(reviews=[reviewed("member", "PostHog/team-commented", "PostHog/team"), reviewed("hogql")])])
        self.assertEqual(result["owners"], [])

    def test_team_names_match_case_insensitively(self):
        self.assertEqual(owners([page(reviews=[reviewed("member", "posthog/HogQL")])])["owners"], ["posthog/HogQL"])

    def test_github_directory_file_wins_over_the_root_file(self):
        pages = [page(reviews=[reviewed("member", "PostHog/root-team")], github="* @PostHog/hogql", root="* @PostHog/root-team")]
        self.assertEqual(owners(pages)["owners"], [])
        pages = [page(reviews=[reviewed("member", "PostHog/root-team")], github=None, root="* @PostHog/root-team")]
        self.assertEqual(owners(pages)["owners"], ["PostHog/root-team"])

    def test_docs_directory_file_is_read_last(self):
        pages = [page(reviews=[reviewed("member", "PostHog/docs-team")], github=None, root="* @PostHog/root-team", docs="* @PostHog/docs-team")]
        self.assertEqual(owners(pages)["owners"], [])
        pages = [page(reviews=[reviewed("member", "PostHog/docs-team")], github=None, docs="* @PostHog/docs-team")]
        self.assertEqual(owners(pages)["owners"], ["PostHog/docs-team"])

    def test_reviews_on_later_pages_count(self):
        pages = [page(reviews=[reviewed()]), page(reviews=[reviewed("member", "PostHog/team-frontend")])]
        self.assertEqual(owners(pages)["owners"], ["PostHog/team-frontend"])


class RequirementTest(unittest.TestCase):
    def gated_page(self, **kwargs):
        return [page([request("PostHog/hogql")], [reviewed("member", "PostHog/team-frontend")], **kwargs)]

    def test_no_owners_when_no_rule_requires_code_owner_review(self):
        for rules in ([], [{"type": "pull_request", "parameters": {"require_code_owner_review": False}}], [{"type": "deletion"}]):
            with self.subTest(rules=rules):
                self.assertEqual(owners(self.gated_page(), rules), {"owners": [], "pending": []})

    def test_branch_protection_rule_requires_code_owner_review(self):
        result = owners(self.gated_page(protection={"requiresCodeOwnerReviews": True}), [])
        self.assertEqual(result["owners"], ["PostHog/hogql", "PostHog/team-frontend"])

    def test_branch_protection_rule_without_code_owner_review(self):
        self.assertEqual(owners(self.gated_page(protection={"requiresCodeOwnerReviews": False}), [])["owners"], [])


class MainTest(unittest.TestCase):
    def run_main(self, responses):
        calls = []

        def fake_run(args, **_kwargs):
            calls.append(args)
            code, out = responses.pop(0)
            return subprocess.CompletedProcess(args, code, stdout=out, stderr="boom" if code else "")

        out = io.StringIO()
        with mock.patch("subprocess.run", fake_run), mock.patch("sys.stdout", out):
            code = code_owners.main(["--pr", "7"])
        return code, json.loads(out.getvalue()), calls

    def test_prints_owners_and_reads_the_base_branch_rules(self):
        code, result, calls = self.run_main([
            (0, json.dumps({"url": "https://github.com/PostHog/posthog/pull/7", "baseRefName": "main"})),
            (0, json.dumps([page([request("PostHog/hogql")])])),
            (0, json.dumps([REQUIRED])),
        ])
        self.assertEqual((code, result), (0, {"owners": ["PostHog/hogql"], "pending": ["PostHog/hogql"]}))
        self.assertIn("repos/PostHog/posthog/rules/branches/main?per_page=100", calls[2])

    def test_gh_failure_exits_1(self):
        code, result, _ = self.run_main([(1, "")])
        self.assertEqual(code, 1)
        self.assertIn("boom", result["error"])

    def test_unparseable_pr_url_exits_1(self):
        code, result, _ = self.run_main([(0, json.dumps({"url": "https://example.com/x", "baseRefName": "main"}))])
        self.assertEqual(code, 1)
        self.assertIn("could not read the repository", result["error"])

    def test_malformed_response_exits_1(self):
        code, result, _ = self.run_main([
            (0, json.dumps({"url": "https://github.com/PostHog/posthog/pull/7", "baseRefName": "main"})),
            (0, json.dumps([{"data": {}}])),
            (0, json.dumps([REQUIRED])),
        ])
        self.assertEqual(code, 1)
        self.assertIn("error", result)


if __name__ == "__main__":
    unittest.main()
