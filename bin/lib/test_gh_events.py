import contextlib
import datetime as dt
import importlib.machinery
import importlib.util
import io
import json
import os
from pathlib import Path
import tempfile
import time
import unittest
from unittest import mock


SCRIPT = Path(__file__).resolve().parents[1] / "gh-events"
LOADER = importlib.machinery.SourceFileLoader("gh_events", str(SCRIPT))
SPEC = importlib.util.spec_from_loader("gh_events", LOADER)
gh_events = importlib.util.module_from_spec(SPEC)
LOADER.exec_module(gh_events)

API = gh_events.API
REPO = "PostHog/posthog"
PR_URL = f"{API}/repos/{REPO}/pulls/7"
REVIEWS_URL = f"{PR_URL}/reviews?per_page=100"
NOTIFICATIONS_URL = f"{API}/notifications?all=true&participating=true&per_page=50"
SHA = "a" * 40
SUITES_URL = f"{API}/repos/{REPO}/commits/{SHA}/check-suites?per_page=100"
STATUS_URL = f"{API}/repos/{REPO}/commits/{SHA}/status?per_page=100"
T0 = dt.datetime(2026, 11, 5, 12, 0, 0, tzinfo=dt.timezone.utc)


def ts(minutes=0):
    return gh_events.iso(T0 + dt.timedelta(minutes=minutes))


class FakeGitHub:
    """Serves bodies by URL, returning 304 when the client's ETag matches the body."""

    def __init__(self):
        self.bodies = {}
        self.extra_headers = {}
        self.calls = []

    def set(self, url, body, headers=None):
        self.bodies[url] = json.dumps(body)
        self.extra_headers[url] = headers or {}

    def __call__(self, url, headers):
        self.calls.append((url, dict(headers)))
        if url not in self.bodies:
            return 404, {}, b'{"message": "Not Found"}'
        body = self.bodies[url]
        etag = '"' + str(hash(body)) + '"'
        response_headers = dict(self.extra_headers[url], etag=etag)
        if headers.get("If-None-Match") == etag:
            return 304, response_headers, b""
        return 200, response_headers, body.encode()

    def conditional(self, url):
        return [h.get("If-None-Match") is not None for u, h in self.calls if u == url]


def pull(state="open", merged_at=None, closed_at=None, requested=(), teams=(), updated=None, sha=SHA):
    return {
        "html_url": f"https://github.com/{REPO}/pull/7",
        "state": state,
        "merged_at": merged_at,
        "merged_by": {"login": "haacked"} if merged_at else None,
        "merge_commit_sha": "m" * 40 if merged_at else None,
        "closed_at": closed_at,
        "updated_at": updated or ts(1),
        "requested_reviewers": [{"login": login} for login in requested],
        "requested_teams": [{"slug": slug} for slug in teams],
        "head": {"sha": sha},
    }


def review(review_id, at, state="APPROVED", login="alice"):
    return {"id": review_id, "user": {"login": login}, "state": state, "submitted_at": at, "commit_id": SHA}


def suite(suite_id, status="completed", conclusion="success", runs=1, updated=None, created=None, app="github-actions"):
    return {"id": suite_id, "status": status, "conclusion": conclusion, "latest_check_runs_count": runs,
            "updated_at": updated or ts(2), "created_at": created or ts(-60), "app": {"slug": app}}


class Harness(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.store = gh_events.Store(Path(self.tmp.name))
        self.store.ensure()
        self.fake = FakeGitHub()
        self.now = T0
        self.daemon = self.make_daemon()

    def clock(self):
        return self.now

    def make_daemon(self):
        metrics = gh_events.Metrics(self.store)
        github = gh_events.GitHub(self.store, metrics, transport=self.fake, token_fn=lambda: "tok", clock=self.clock)
        return gh_events.Daemon(self.store, github, clock=self.clock)

    def events(self):
        return gh_events.read_jsonl(self.store.events)

    def kinds(self):
        return [e["kind"] for e in self.events()]

    def refresh(self, cutoff=None, reviews=True):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.daemon.refresh_pr(REPO, 7, cutoff or T0, "watch", reviews)

    def refresh_ci(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.daemon.refresh_ci(REPO, 7, pull(), T0)


class ParseTargetTest(unittest.TestCase):
    def test_accepts_url_and_short_forms(self):
        self.assertEqual(gh_events.parse_target("https://github.com/PostHog/posthog/pull/123"), ("PostHog/posthog", 123))
        self.assertEqual(gh_events.parse_target("https://github.com/PostHog/posthog/pull/123/files"), ("PostHog/posthog", 123))
        self.assertEqual(gh_events.parse_target("PostHog/posthog#9"), ("PostHog/posthog", 9))

    def test_rejects_other_text(self):
        for text in ("123", "PostHog/posthog", "https://github.com/PostHog/posthog/issues/1", "a/b/c#1"):
            with self.assertRaises(ValueError):
                gh_events.parse_target(text)


class ConditionalRequestTest(Harness):
    def test_repeat_request_is_conditional_and_304_returns_cached_body(self):
        self.fake.set(PR_URL, pull())
        changed, data, _ = self.daemon.github.get(PR_URL)
        self.assertTrue(changed)
        changed, again, _ = self.daemon.github.get(PR_URL)
        self.assertFalse(changed)
        self.assertEqual(again, data)
        self.assertEqual(self.fake.conditional(PR_URL), [False, True])
        day = self.daemon.github.metrics.data["days"]["2026-11-05"]["pull"]
        self.assertEqual(day, {"requests": 2, "not_modified": 1, "errors": 0})

    def test_follows_next_links(self):
        page2 = f"{REVIEWS_URL}&page=2"
        self.fake.set(REVIEWS_URL, [review(1, ts(1))], {"link": f'<{page2}>; rel="next"'})
        self.fake.set(page2, [review(2, ts(2))])
        items = self.daemon.github.get_all(REVIEWS_URL)
        self.assertEqual([r["id"] for r in items], [1, 2])

    def test_rate_limit_raises_with_reset(self):
        self.fake.set(PR_URL, {}, {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1999999999"})
        original = self.fake.__call__

        def limited(url, headers):
            _, headers_out, body = original(url, headers)
            return 403, headers_out, body
        self.daemon.github.transport = limited
        with self.assertRaises(gh_events.RateLimited) as caught:
            self.daemon.github.get(PR_URL)
        self.assertEqual(caught.exception.reset_at, 1999999999.0)

    def test_retries_once_with_a_new_token_on_401(self):
        tokens = iter(["old", "new"])
        self.daemon.github.token_fn = lambda: next(tokens)
        seen = []

        def transport(url, headers):
            seen.append(headers["Authorization"])
            return (401, {}, b"") if headers["Authorization"] == "Bearer old" else (200, {}, b"{}")
        self.daemon.github.transport = transport
        self.assertEqual(self.daemon.github.get(PR_URL)[1], {})
        self.assertEqual(seen, ["Bearer old", "Bearer new"])

    def test_network_error_returns_none_and_counts_an_error(self):
        def broken(url, headers):
            raise OSError("offline")
        self.daemon.github.transport = broken
        with contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(self.daemon.github.get(PR_URL), (False, None, None))
        self.assertEqual(self.daemon.github.metrics.data["days"]["2026-11-05"]["pull"]["errors"], 1)
        self.assertEqual(self.daemon.github.metrics.data["sources"]["2026-11-05"]["other"]["errors"], 1)


class RefreshPrTest(Harness):
    def test_first_refresh_emits_only_reviews_after_the_cutoff(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(1, ts(-60)), review(2, ts(1), "CHANGES_REQUESTED", "copilot[bot]")])
        self.refresh(cutoff=T0)
        events = self.events()
        self.assertEqual([e["review_id"] for e in events], [2])
        self.assertEqual(events[0]["state"], "changes_requested")
        self.assertEqual(events[0]["actor"], "copilot[bot]")
        for field in ("ts", "kind", "repo", "pr", "url", "actor", "source", "source_ts", "id"):
            self.assertIn(field, events[0])

    def test_later_review_emits_once_and_a_restart_emits_nothing(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.now = T0 + dt.timedelta(minutes=2)
        self.fake.set(REVIEWS_URL, [review(5, ts(2))])
        self.refresh()
        self.refresh()
        self.daemon = self.make_daemon()
        self.refresh()
        self.assertEqual(self.kinds(), ["review_submitted"])

    def test_pending_reviews_are_ignored(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(9, ts(1), "PENDING")])
        self.refresh()
        self.assertEqual(self.events(), [])

    def test_stale_snapshot_does_not_replay_old_reviews(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.now = T0 + dt.timedelta(days=3)
        self.fake.set(REVIEWS_URL, [review(5, ts(60))])
        self.refresh(cutoff=self.now)
        self.assertEqual(self.events(), [])

    def test_refresh_without_reviews_keeps_the_review_cutoff(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.now = T0 + dt.timedelta(minutes=20)
        self.refresh(cutoff=self.now, reviews=False)
        self.fake.set(REVIEWS_URL, [review(8, ts(5))])
        self.refresh()
        self.assertEqual(self.kinds(), ["review_submitted"])

    def test_watch_events_from_before_the_watch_are_flagged(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(1, ts(-2)), review(2, ts(1))])
        self.refresh(cutoff=T0)
        self.assertEqual([(e["review_id"], e["before_watch"]) for e in self.events()], [(1, True), (2, False)])

    def test_ci_only_refresh_then_reviews_does_not_flood_history(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(1, ts(-600)), review(2, ts(-300))])
        self.refresh(reviews=False)
        self.refresh(reviews=True)
        self.assertEqual(self.events(), [])

    def test_merge_emits_once_with_actor(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.fake.set(PR_URL, pull(state="closed", merged_at=ts(3), closed_at=ts(3)))
        self.refresh()
        self.refresh()
        events = self.events()
        self.assertEqual([e["kind"] for e in events], ["merged"])
        self.assertEqual(events[0]["actor"], "haacked")
        self.assertEqual(events[0]["merge_commit_sha"], "m" * 40)

    def test_merge_before_the_cutoff_is_not_emitted(self):
        self.fake.set(PR_URL, pull(state="closed", merged_at=ts(-60), closed_at=ts(-60)))
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.assertEqual(self.events(), [])

    def test_close_reopen_close_emits_two_closed_events(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.fake.set(PR_URL, pull(state="closed", closed_at=ts(2)))
        self.refresh()
        self.fake.set(PR_URL, pull(state="open"))
        self.refresh()
        self.fake.set(PR_URL, pull(state="closed", closed_at=ts(4)))
        self.refresh()
        self.assertEqual(self.kinds(), ["closed", "closed"])

    def test_newly_requested_reviewers_emit_review_requested(self):
        self.fake.set(PR_URL, pull(requested=["alice"]))
        self.fake.set(REVIEWS_URL, [])
        self.refresh()
        self.fake.set(PR_URL, pull(requested=["alice", "copilot"], teams=["flags"], updated=ts(2)))
        self.refresh()
        events = self.events()
        self.assertEqual(sorted((e["reviewer_type"], e["reviewer"]) for e in events), [("team", "flags"), ("user", "copilot")])

    def test_failed_fetch_returns_none_and_writes_no_snapshot(self):
        self.assertIsNone(self.refresh())
        self.assertEqual(list(self.store.prs_dir.iterdir()), [])


class RefreshCiTest(Harness):
    def setUp(self):
        super().setUp()
        self.fake.set(STATUS_URL, {"state": "pending", "total_count": 0, "statuses": []})

    def test_in_progress_suite_is_not_complete(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1), suite(2, "in_progress", None)]})
        self.assertFalse(self.refresh_ci())
        self.assertEqual(self.events(), [])

    def test_in_progress_suite_skips_the_status_request(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1, "in_progress", None)]})
        self.refresh_ci()
        self.assertNotIn(STATUS_URL, [u for u, _ in self.fake.calls])

    def test_new_head_forgets_the_old_heads_ci_cache(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.refresh_ci()
        self.refresh()
        self.assertTrue(self.daemon.github.cache_path(SUITES_URL).exists())
        self.fake.set(PR_URL, pull(sha="b" * 40))
        self.refresh()
        self.assertFalse(self.daemon.github.cache_path(SUITES_URL).exists())
        self.assertFalse(self.daemon.github.cache_path(STATUS_URL).exists())

    def test_new_suite_without_runs_yet_is_pending(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1), suite(2, "queued", None, runs=0, created=ts(-1))]})
        self.assertFalse(self.refresh_ci())
        self.assertEqual(self.events(), [])

    def test_new_suite_without_runs_from_another_app_is_ignored(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1), suite(2, "queued", None, runs=0, created=ts(-1), app="claude")]})
        self.assertTrue(self.refresh_ci())
        self.assertEqual([e["kind"] for e in self.events()], ["ci_completed"])

    def test_no_checks_yet_is_not_complete(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1, "queued", None, runs=0)]})
        self.assertFalse(self.refresh_ci())

    def test_all_suites_passed_emits_pass_once(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1), suite(2, conclusion="skipped"), suite(3, "queued", None, runs=0)]})
        self.assertTrue(self.refresh_ci())
        self.assertTrue(self.refresh_ci())
        events = self.events()
        self.assertEqual([(e["kind"], e["result"]) for e in events], [("ci_completed", "pass")])
        self.assertEqual(events[0]["counts"]["check_suites"], {"success": 1, "skipped": 1})
        self.assertEqual(events[0]["head_sha"], SHA)
        self.assertFalse(events[0]["before_watch"])

    def test_checks_finished_before_the_watch_are_flagged(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1, updated=ts(-30))]})
        self.refresh_ci()
        self.assertTrue(self.events()[0]["before_watch"])

    def test_failed_suite_or_status_reports_fail(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1, conclusion="failure")]})
        self.refresh_ci()
        self.assertEqual(self.events()[-1]["result"], "fail")

    def test_failed_commit_status_reports_fail(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.fake.set(STATUS_URL, {"state": "failure", "total_count": 1, "statuses": [{"context": "depot", "state": "failure", "updated_at": ts(3)}]})
        self.refresh_ci()
        self.assertEqual(self.events()[-1]["result"], "fail")
        self.assertEqual(self.events()[-1]["source_ts"], ts(3))

    def test_pending_commit_status_blocks_completion(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.fake.set(STATUS_URL, {"state": "pending", "total_count": 1, "statuses": [{"context": "depot", "state": "pending"}]})
        self.assertFalse(self.refresh_ci())

    def test_rerun_with_the_same_conclusion_emits_again(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1, conclusion="failure", updated=ts(2))]})
        self.refresh_ci()
        self.fake.set(SUITES_URL, {"check_suites": [suite(1, conclusion="failure", updated=ts(9))]})
        self.refresh_ci()
        self.assertEqual([e["result"] for e in self.events()], ["fail", "fail"])

    def test_late_suite_emits_again_after_it_finishes(self):
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.refresh_ci()
        self.fake.set(SUITES_URL, {"check_suites": [suite(1), suite(2, "in_progress", None)]})
        self.assertFalse(self.refresh_ci())
        self.fake.set(SUITES_URL, {"check_suites": [suite(1), suite(2, conclusion="failure")]})
        self.refresh_ci()
        self.assertEqual([e["result"] for e in self.events()], ["pass", "fail"])


class WatchTest(Harness):
    def watches(self):
        return gh_events.Watches(self.store)

    def test_register_merges_flags_and_keeps_the_later_expiry(self):
        self.watches().register(REPO, 7, {"ci_completed"}, ttl=3600, now=T0)
        watch = self.watches().register(REPO, 7, {"review_submitted", "merged"}, ttl=60, now=T0)
        self.assertEqual((watch["kinds"], watch["expires_at"]), (["ci_completed", "merged", "review_submitted"], ts(60)))

    def test_expired_watch_is_removed(self):
        self.watches().register(REPO, 7, {"ci_completed"}, ttl=60, now=T0)
        self.assertEqual(self.watches().active(T0 + dt.timedelta(minutes=2)), [])
        self.assertEqual(list(self.store.watches_dir.glob("*.json")), [])

    def poll(self, monotonic=0.0):
        with contextlib.redirect_stdout(io.StringIO()):
            self.daemon.poll_watches(monotonic)

    def test_ci_watch_is_dropped_after_ci_completes(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.fake.set(STATUS_URL, {"state": "pending", "total_count": 0, "statuses": []})
        self.watches().register(REPO, 7, {"ci_completed"}, ttl=600, now=T0)
        self.poll()
        self.assertEqual(self.kinds(), ["ci_completed"])
        self.assertEqual(self.watches().active(T0), [])

    def test_ci_and_reviews_watch_keeps_reviews_after_ci(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.fake.set(STATUS_URL, {"state": "pending", "total_count": 0, "statuses": []})
        self.watches().register(REPO, 7, {"ci_completed", "review_submitted"}, ttl=600, now=T0)
        self.poll()
        [watch] = self.watches().active(T0)
        self.assertEqual(watch["kinds"], ["review_submitted"])

    def test_merge_waiter_keeps_the_watch_after_ci_completes(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(SUITES_URL, {"check_suites": [suite(1)]})
        self.fake.set(STATUS_URL, {"state": "pending", "total_count": 0, "statuses": []})
        self.watches().register(REPO, 7, {"ci_completed"}, ttl=600, now=T0)
        self.watches().register(REPO, 7, {"merged", "closed"}, ttl=600, now=T0)
        self.poll()
        [watch] = self.watches().active(T0)
        self.assertEqual(watch["kinds"], ["closed", "merged"])

    def test_closed_pr_drops_the_watch(self):
        self.fake.set(PR_URL, pull(state="closed", merged_at=ts(1), closed_at=ts(1)))
        self.watches().register(REPO, 7, {"ci_completed"}, ttl=600, now=T0)
        self.poll()
        self.assertEqual(self.kinds(), ["merged"])
        self.assertEqual(self.watches().active(T0), [])

    def test_watch_is_not_repolled_within_the_interval(self):
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        self.watches().register(REPO, 7, {"review_submitted"}, ttl=600, now=T0)
        self.poll(0.0)
        self.poll(10.0)
        self.poll(gh_events.WATCH_POLL_SECONDS + 1.0)
        self.assertEqual(len([u for u, _ in self.fake.calls if u == PR_URL]), 2)


class NotificationsTest(Harness):
    def thread(self, thread_id, updated, reason="author", kind="PullRequest"):
        return {"id": thread_id, "reason": reason, "updated_at": updated,
                "subject": {"type": kind, "url": PR_URL if kind == "PullRequest" else None}}

    def poll(self):
        with contextlib.redirect_stdout(io.StringIO()):
            return self.daemon.poll_notifications()

    def test_first_poll_records_threads_without_refreshing_them(self):
        self.fake.set(NOTIFICATIONS_URL, [self.thread("1", ts(-5))], {"x-poll-interval": "60"})
        self.poll()
        self.assertNotIn(PR_URL, [u for u, _ in self.fake.calls])
        self.assertEqual(self.daemon.state["threads"], {"1": ts(-5)})

    def test_updated_thread_refreshes_its_pr_and_emits(self):
        self.fake.set(NOTIFICATIONS_URL, [], {"x-poll-interval": "120"})
        self.assertEqual(self.poll(), 120)
        self.now = T0 + dt.timedelta(minutes=3)
        self.fake.set(NOTIFICATIONS_URL, [self.thread("1", ts(2)), self.thread("2", ts(2), "ci_activity", "CheckSuite")])
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(4, ts(2))])
        self.poll()
        self.assertEqual([(e["kind"], e["source"]) for e in self.events()], [("review_submitted", "notifications")])
        self.assertNotIn("before_watch", self.events()[0])

    def review_request_thread(self, requested):
        self.daemon.state["login"] = "haacked"
        self.fake.set(NOTIFICATIONS_URL, [])
        self.poll()
        self.now = T0 + dt.timedelta(minutes=3)
        self.fake.set(NOTIFICATIONS_URL, [self.thread("1", ts(2), "review_requested")])
        self.fake.set(PR_URL, pull(requested=requested))
        self.fake.set(REVIEWS_URL, [])
        self.poll()

    def test_first_seen_review_request_names_the_user(self):
        self.review_request_thread(["haacked"])
        self.assertEqual([(e["kind"], e["reviewer"], e["source"]) for e in self.events()],
                         [("review_requested", "haacked", "notifications")])

    def test_review_request_thread_without_an_open_request_emits_nothing(self):
        self.review_request_thread(["alice"])
        self.assertEqual(self.events(), [])

    def test_unchanged_notifications_return_304_and_refresh_nothing(self):
        self.fake.set(NOTIFICATIONS_URL, [self.thread("1", ts(-5))])
        self.poll()
        self.poll()
        self.assertEqual(self.fake.conditional(NOTIFICATIONS_URL), [False, True])

    def test_rate_limit_while_processing_forces_an_unconditional_retry(self):
        self.fake.set(NOTIFICATIONS_URL, [])
        self.poll()
        self.now = T0 + dt.timedelta(minutes=3)
        self.fake.set(NOTIFICATIONS_URL, [self.thread("1", ts(2))])
        self.fake.set(PR_URL, pull(), {"x-ratelimit-remaining": "0", "x-ratelimit-reset": "1"})
        original = self.fake.__call__
        self.daemon.github.transport = lambda url, headers: (403, *original(url, headers)[1:]) if url == PR_URL else original(url, headers)
        with self.assertRaises(gh_events.RateLimited):
            self.poll()
        self.daemon.github.transport = original
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(4, ts(2))])
        self.poll()
        self.assertEqual(self.kinds(), ["review_submitted"])

    def test_threads_older_than_a_day_before_the_cutoff_are_dropped(self):
        self.fake.set(NOTIFICATIONS_URL, [self.thread("old", ts(-3 * 24 * 60)), self.thread("new", ts(-5))])
        self.poll()
        self.assertEqual(self.daemon.state["threads"], {"new": ts(-5)})

    def test_failed_pr_refresh_forces_an_unconditional_retry(self):
        self.fake.set(NOTIFICATIONS_URL, [])
        self.poll()
        self.now = T0 + dt.timedelta(minutes=3)
        self.fake.set(NOTIFICATIONS_URL, [self.thread("1", ts(2))])
        self.poll()
        self.assertEqual(self.daemon.state["threads"], {})
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [review(4, ts(2))])
        self.poll()
        self.assertEqual(self.fake.conditional(NOTIFICATIONS_URL)[-1], False)
        self.assertEqual(self.kinds(), ["review_submitted"])


class RequestSourceTest(Harness):
    def sources(self):
        return self.daemon.github.metrics.data["sources"]["2026-11-05"]

    def test_start_records_the_run_and_counts_its_request_apart(self):
        with contextlib.redirect_stdout(io.StringIO()):
            self.daemon.start()
        self.assertEqual(gh_events.read_jsonl(self.store.runs), [{"started_at": ts(0)}])
        self.daemon.github.metrics.flush()
        self.assertEqual(self.sources(), {"start": {"requests": 1, "not_modified": 0, "errors": 1}})

    def test_tick_counts_notification_and_watch_requests_by_source(self):
        self.fake.set(NOTIFICATIONS_URL, [])
        self.fake.set(PR_URL, pull())
        self.fake.set(REVIEWS_URL, [])
        gh_events.Watches(self.store).register(REPO, 7, {"review_submitted"}, ttl=600, now=T0)
        with contextlib.redirect_stdout(io.StringIO()):
            self.daemon.tick(0.0)
            self.daemon.tick(gh_events.MIN_NOTIFICATION_SECONDS + 1.0)
        self.assertEqual(self.sources(), {
            "notifications": {"requests": 2, "not_modified": 1, "errors": 0},
            "watch": {"requests": 4, "not_modified": 2, "errors": 0},
        })

    def test_metrics_file_without_sources_still_loads(self):
        gh_events.Store.write_json(self.store.metrics, {"days": {"2026-11-04": {"pull": {"requests": 3, "not_modified": 1, "errors": 0}}}})
        self.assertEqual(gh_events.compute_stats(self.store)["requests_by_day"]["2026-11-04"]["by_source"], {})
        self.daemon = self.make_daemon()
        self.fake.set(PR_URL, pull())
        self.daemon.github.get(PR_URL)
        self.daemon.github.metrics.flush()
        requests = gh_events.compute_stats(self.store)["requests_by_day"]
        self.assertEqual(requests["2026-11-04"]["counted_against_rate_limit"], 2)
        self.assertEqual(requests["2026-11-04"]["by_source"], {})
        self.assertEqual(requests["2026-11-05"]["by_source"],
                         {"other": {"requests": 1, "not_modified": 0, "errors": 0, "counted_against_rate_limit": 1}})


class WaitTest(Harness):
    def setUp(self):
        super().setUp()
        self.store.heartbeat.write_text("{}")

    def append(self, **event):
        base = {"ts": ts(1), "kind": "review_submitted", "repo": REPO, "pr": 7}
        gh_events.Store.append_line(self.store.events, dict(base, **event))

    def wait(self, kinds=("review_submitted",), since=T0, timeout=0.0, **kwargs):
        return gh_events.wait_for_event(self.store, "posthog/POSTHOG", 7, set(kinds), since, timeout,
                                        poll_seconds=0.01, **kwargs)

    def test_matches_repo_case_insensitively_and_ignores_other_events(self):
        self.append(pr=8)
        self.append(kind="merged")
        self.append(ts=ts(-1))
        self.append(id="match")
        code, event = self.wait()
        self.assertEqual((code, event["id"]), (0, "match"))

    def test_times_out_without_a_match(self):
        self.append(pr=8)
        self.assertEqual(self.wait(), (gh_events.EXIT_TIMEOUT, None))

    def test_wakes_on_an_event_appended_while_waiting(self):
        calls = []

        def sleep(seconds):
            calls.append(seconds)
            if len(calls) == 2:
                self.append(id="late")
        code, event = self.wait(timeout=60, sleep=sleep)
        self.assertEqual((code, event["id"]), (0, "late"))

    def test_partial_line_is_read_once_complete(self):
        with open(self.store.events, "w") as handle:
            handle.write('{"ts": "%s", "kind": "review_submitted", "repo": "%s", "pr": 7, "id": "x"' % (ts(1), REPO))
        offset, lines = gh_events.read_new_lines(self.store.events, 0)
        self.assertEqual((offset, lines), (0, []))
        with open(self.store.events, "a") as handle:
            handle.write("}\n")
        self.assertEqual(self.wait()[1]["id"], "x")

    def test_reports_daemon_down_when_the_heartbeat_goes_stale(self):
        old = time.time() - gh_events.ALIVE_SECONDS - 10
        os.utime(self.store.heartbeat, (old, old))
        self.assertEqual(self.wait(timeout=60), (gh_events.EXIT_DAEMON_DOWN, None))


class CommandTest(Harness):
    def run_main(self, *argv):
        out, err = io.StringIO(), io.StringIO()
        with mock.patch.dict(os.environ, {"GH_EVENTS_STATE_DIR": self.tmp.name}), \
                contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            code = gh_events.main(list(argv))
        return code, out.getvalue(), err.getvalue()

    def test_wait_and_watch_exit_3_without_a_daemon(self):
        self.assertEqual(self.run_main("wait", f"{REPO}#7", "--kind", "ci_completed", "--timeout", "1")[0], 3)
        self.assertEqual(self.run_main("watch", f"{REPO}#7", "--ci")[0], 3)
        self.assertEqual(list(self.store.watches_dir.glob("*.json")), [])
        [record] = gh_events.read_jsonl(self.store.waits)
        self.assertEqual(record["outcome"], "daemon_down")

    def test_wait_registers_the_watch_its_kinds_need_and_logs_the_outcome(self):
        self.store.heartbeat.write_text("{}")
        gh_events.Store.append_line(self.store.events, {"ts": gh_events.iso(gh_events.utcnow()), "kind": "ci_completed",
                                                         "repo": REPO, "pr": 7, "id": "ci:1"})
        code, out, _ = self.run_main("wait", f"https://github.com/{REPO}/pull/7", "--kind", "ci_completed,merged",
                                     "--since", ts(-60), "--timeout", "5")
        self.assertEqual((code, json.loads(out)["id"]), (0, "ci:1"))
        [watch] = gh_events.Watches(self.store).active(gh_events.utcnow())
        self.assertEqual(watch["kinds"], ["ci_completed", "merged"])
        [record] = gh_events.read_jsonl(self.store.waits)
        self.assertEqual((record["outcome"], record["event_id"]), ("matched", "ci:1"))

    def test_wait_rejects_an_unknown_kind(self):
        self.assertEqual(self.run_main("wait", f"{REPO}#7", "--kind", "deployed")[0], 1)

    def test_stats_reports_304s_latency_and_waits(self):
        self.fake.set(PR_URL, pull())
        self.daemon.github.get(PR_URL)
        self.daemon.github.get(PR_URL)
        self.daemon.github.metrics.flush()
        gh_events.Store.append_line(self.store.events, {"ts": ts(2), "source_ts": ts(1), "kind": "merged", "source": "watch"})
        gh_events.Store.append_line(self.store.events, {"ts": ts(90), "source_ts": ts(1), "kind": "merged", "source": "watch", "before_watch": True})
        gh_events.Store.append_line(self.store.waits, {"kinds": ["merged"], "outcome": "timeout"})
        stats = gh_events.compute_stats(self.store)
        day = stats["requests_by_day"]["2026-11-05"]
        self.assertEqual((day["requests"], day["not_modified"], day["counted_against_rate_limit"]), (2, 1, 1))
        self.assertEqual(stats["events"]["merged/watch"], {"count": 2, "latency_s": {"n": 1, "p50": 60.0, "p90": 60.0, "max": 60.0}})
        self.assertEqual(stats["waits"], {"merged": {"timeout": 1}})

    def test_stats_leaves_events_from_before_their_run_out_of_latency(self):
        for started in (ts(0), ts(10)):
            gh_events.Store.append_line(self.store.runs, {"started_at": started})
        for seen, happened in ((ts(-5), ts(-8)), (ts(5), ts(4)), (ts(10), ts(9)), (ts(12), ts(9)), (ts(12), "2026-11-05T12:09:59Z"), (ts(12), ts(10))):
            gh_events.Store.append_line(self.store.events, {"ts": seen, "source_ts": happened, "kind": "review_submitted", "source": "notifications"})
        group = gh_events.compute_stats(self.store)["events"]["review_submitted/notifications"]
        self.assertEqual(group, {"count": 6, "latency_s": {"n": 3, "p50": 120.0, "p90": 180.0, "max": 180.0}})


if __name__ == "__main__":
    unittest.main()
