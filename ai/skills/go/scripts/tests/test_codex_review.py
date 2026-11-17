import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import textwrap
import time
import unittest


RUNNER = Path(__file__).resolve().parents[1] / "codex-review.py"
PR_URL = "https://github.com/org/repo/pull/123"
FINDING = {
    "file": "app.txt",
    "line": 1,
    "severity": "high",
    "title": "Wrong value",
    "breaks": "The value is wrong.",
    "input": "Any read of app.txt returns the wrong value.",
}
SHIM = r"""
import json
import os
from pathlib import Path
import subprocess
import sys
import time

name = Path(sys.argv[0]).name
args = sys.argv[1:]
mode = os.environ.get("REVIEW_TEST_MODE", "success")
with open(os.environ["REVIEW_TEST_CALLS"], "a") as calls:
    calls.write(json.dumps({"tool": name, "args": args}) + "\n")
if name == "gh":
    if mode == "gh_failure":
        print("could not resolve to a PullRequest", file=sys.stderr)
        sys.exit(1)
    print(json.dumps({"title": os.environ["REVIEW_TEST_PR_TITLE"], "body": os.environ["REVIEW_TEST_PR_BODY"]}))
    sys.exit(0)
if name != "codex":
    sys.exit(9)
if args[:2] == ["login", "status"]:
    if mode == "signed_out":
        print("Not logged in")
        sys.exit(1)
    print("Logged in using ChatGPT")
    sys.exit(0)
root = Path.cwd()
prompt = sys.stdin.read()
with open(os.environ["REVIEW_TEST_PROMPTS"], "a") as prompts:
    prompts.write(json.dumps({"prompt": prompt, "args": args}) + "\n")
if mode == "edit":
    (root / "app.txt").write_text("review edit\n")
if mode == "descendants":
    child_code = (
        "import fcntl, os, pathlib, signal, time; "
        "signal.signal(signal.SIGTERM, signal.SIG_IGN); "
        "ready = pathlib.Path(os.environ['REVIEW_TEST_DESCENDANT']); "
        "live = ready.with_suffix('.alive').open('w'); "
        "fcntl.flock(live, fcntl.LOCK_EX); "
        "temporary = ready.with_suffix('.tmp'); "
        "temporary.write_text(str(os.getpid())); temporary.replace(ready); "
        "time.sleep(30)"
    )
    subprocess.Popen([sys.executable, "-c", child_code], stdout=subprocess.DEVNULL,
                     stderr=subprocess.DEVNULL)
    deadline = time.monotonic() + 3
    while not Path(os.environ["REVIEW_TEST_DESCENDANT"]).exists():
        if time.monotonic() >= deadline:
            sys.exit(8)
        time.sleep(0.01)
    time.sleep(30)
if mode == "failure":
    print("fixture codex failure", file=sys.stderr)
    sys.exit(7)
events = [{"type": "thread.started"}, {"type": "turn.started"}]
if mode == "turn_failed":
    events.append({"type": "turn.failed"})
elif mode != "incomplete":
    events.append({"type": "turn.completed"})
for event in events:
    print(json.dumps(event))
result = json.loads(os.environ["REVIEW_TEST_RESULT"])
result_path = Path(args[args.index("--output-last-message") + 1])
result_path.write_text("{invalid JSON" if mode == "malformed" else json.dumps(result))
"""


class CodexReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="go-review-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "checkout with spaces"
        self.repo.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.descendant_file = self.root / "descendant.pid"
        self.addCleanup(self.cleanup_descendant)
        self.shims = self.root / "bin"
        self.shims.mkdir()
        self.calls_file = self.root / "calls.jsonl"
        self.prompts_file = self.root / "prompts.jsonl"
        self.state_path = self.repo / ".notes/go-codex-review-state.json"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "REVIEW_TEST_", "CODEX_"))
        }
        self.env.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.shims}:/usr/bin:/bin",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "REVIEW_TEST_CALLS": str(self.calls_file),
                "REVIEW_TEST_PROMPTS": str(self.prompts_file),
                "REVIEW_TEST_DESCENDANT": str(self.descendant_file),
                "REVIEW_TEST_PR_TITLE": "Fix the value",
                "REVIEW_TEST_PR_BODY": "Makes app.txt hold the right value.",
                "REVIEW_TEST_RESULT": json.dumps(
                    {
                        "status": "completed",
                        "summary": "One bug.",
                        "findings": [FINDING],
                    }
                ),
            }
        )
        for tool in ("codex", "gh"):
            self.add_shim(tool)
        self.git("init", "-q", "-b", "main")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / ".git/info/exclude").write_text(".notes/\n")
        (self.repo / "app.txt").write_text("original\n")
        self.git("add", "app.txt")
        self.git("commit", "-qm", "Initial fixture")
        self.base = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "feature")
        self.commit("changed\n", "Change the value")

    def add_shim(self, tool):
        path = self.shims / tool
        path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(SHIM))
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def commit(self, contents, message):
        (self.repo / "app.txt").write_text(contents)
        self.git("commit", "-qam", message)

    def invoke(self, *args, mode="success", timeout=10):
        env = dict(self.env, REVIEW_TEST_MODE=mode)
        return subprocess.run(
            [sys.executable, str(RUNNER), *args],
            cwd=self.repo,
            env=env,
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def run_review(self, *extra, base=None, **kwargs):
        return self.invoke(
            "run", "--pr-url", PR_URL, "--base", base or self.base, *extra, **kwargs
        )

    def calls(self, tool=None):
        if not self.calls_file.exists():
            return []
        calls = [json.loads(line) for line in self.calls_file.read_text().splitlines()]
        return [call for call in calls if tool is None or call["tool"] == tool]

    def reviews(self):
        if not self.prompts_file.exists():
            return []
        return [json.loads(line) for line in self.prompts_file.read_text().splitlines()]

    def state(self):
        return json.loads(self.state_path.read_text())

    def output(self, result):
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(result.stdout)

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
        state = self.output(result)
        self.assertEqual(state["phase"], "reviewed")
        self.assertEqual(state["next_action"], "verify-findings")
        return state

    def assert_failed(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        state = self.state()
        self.assertEqual(state["phase"], "failed")
        self.assertEqual(state["next_action"], "inspect-review-failure")
        self.assertIn(message, state["error"])
        return state

    def assert_refused(self, result, message):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn(message, result.stderr)
        self.assertEqual(self.reviews(), [])
        self.assertFalse(self.state_path.exists())

    def descendant_alive(self):
        live = self.descendant_file.with_suffix(".alive")
        if not live.exists():
            return False
        with live.open("r") as handle:
            try:
                fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                return True
        return False

    def cleanup_descendant(self):
        if self.descendant_alive():
            try:
                os.kill(int(self.descendant_file.read_text()), signal.SIGKILL)
            except ProcessLookupError:
                pass

    def test_codex_runs_read_only_on_astra_without_skills_or_subagents(self):
        self.assert_success(self.run_review())

        [review] = self.reviews()
        args = review["args"]
        self.assertEqual(args[:2], ["exec", "--json"])
        self.assertIn("--ephemeral", args)
        self.assertEqual(args[args.index("--model") + 1], "gpt-6-astra")
        self.assertEqual(args[args.index("--sandbox") + 1], "read-only")
        disabled = [args[i + 1] for i, arg in enumerate(args) if arg == "--disable"]
        self.assertEqual(sorted(disabled), ["multi_agent", "plugins", "skill_search"])
        configs = [args[i + 1] for i, arg in enumerate(args) if arg == "-c"]
        self.assertIn("skills.include_instructions=false", configs)
        self.assertIn('model_reasoning_effort="high"', configs)
        self.assertEqual(args[args.index("-C") + 1], str(self.repo))

    def test_prompt_names_the_range_and_the_pull_request_intent(self):
        head = self.git("rev-parse", "HEAD")
        plan = self.root / "plan.md"
        plan.write_text("# Plan\n")

        self.assert_success(self.run_review("--intent", str(plan)))

        prompt = self.reviews()[0]["prompt"]
        self.assertIn(f"git diff {self.base}..{head}", prompt)
        self.assertIn("Fix the value", prompt)
        self.assertIn("Makes app.txt hold the right value.", prompt)
        self.assertIn(str(plan), prompt)
        self.assertNotIn("{{", prompt)
        self.assertIn("Do not load or follow an installed skill", prompt)

    def test_placeholders_in_the_pull_request_text_stay_as_written(self):
        self.env["REVIEW_TEST_PR_BODY"] = "Body names {{BASE}} and {{UNKNOWN}}."

        self.assert_success(self.run_review())

        self.assertIn(
            "Body names {{BASE}} and {{UNKNOWN}}.", self.reviews()[0]["prompt"]
        )

    def test_findings_are_saved_with_the_reviewed_range(self):
        state = self.assert_success(self.run_review())

        attempt = self.repo / ".notes/go-codex-reviews" / state["run_id"]
        self.assertEqual(state["findings_file"], str(attempt / "findings.json"))
        self.assertEqual(state["findings_count"], 1)
        self.assertEqual(state["base_sha"], self.base)
        self.assertEqual(state["input_sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(state["model"], "gpt-6-astra")
        saved = json.loads((attempt / "findings.json").read_text())
        self.assertEqual(saved["findings"], [FINDING])
        self.assertEqual(json.loads((attempt / "state.json").read_text()), self.state())

    def test_a_review_with_no_findings_succeeds(self):
        self.env["REVIEW_TEST_RESULT"] = json.dumps(
            {"status": "completed", "summary": "Correct.", "findings": []}
        )

        state = self.assert_success(self.run_review())

        self.assertEqual(state["findings_count"], 0)

    def test_missing_codex_stops_without_falling_back(self):
        (self.shims / "codex").unlink()

        self.assert_failed(self.run_review(), "codex CLI is not installed")

        self.assertEqual(self.calls("gh"), [])

    def test_signed_out_codex_stops_without_falling_back(self):
        state = self.assert_failed(self.run_review(mode="signed_out"), "not signed in")

        self.assertIn("codex login", state["error"])
        self.assertEqual(self.reviews(), [])

    def test_unreadable_pull_request_fails_before_launch(self):
        self.assert_failed(self.run_review(mode="gh_failure"), "Cannot read")

        self.assertEqual(self.reviews(), [])

    def test_review_that_edits_the_checkout_fails(self):
        self.assert_failed(self.run_review(mode="edit"), "changed the checkout")

        self.assertEqual((self.repo / "app.txt").read_text(), "review edit\n")

    def test_unsuccessful_or_malformed_results_fail(self):
        blocked = {"status": "blocked", "summary": "No range.", "findings": []}
        bad_finding = dict(FINDING, line="1")
        bad_severity = dict(FINDING, severity="nit")
        for name, mode, result, message in (
            ("nonzero exit", "failure", None, "exited with status 7"),
            ("failed turn", "turn_failed", None, "unsuccessful"),
            ("no completed turn", "incomplete", None, "did not report"),
            ("invalid JSON", "malformed", None, "Expecting"),
            ("blocked", "success", blocked, "Review blocked: No range."),
            (
                "string line",
                "success",
                {**blocked, "status": "completed", "findings": [bad_finding]},
                "malformed finding",
            ),
            (
                "unknown severity",
                "success",
                {**blocked, "status": "completed", "findings": [bad_severity]},
                "malformed finding",
            ),
            (
                "missing findings",
                "success",
                {"status": "completed", "summary": "x"},
                "malformed",
            ),
        ):
            with self.subTest(name):
                if result is not None:
                    self.env["REVIEW_TEST_RESULT"] = json.dumps(result)
                self.state_path.unlink(missing_ok=True)

                self.assert_failed(self.run_review(mode=mode), message)

    def test_base_must_be_an_ancestor_commit_other_than_head(self):
        head = self.git("rev-parse", "HEAD")
        self.git("checkout", "-qb", "other", self.base)
        self.commit("other\n", "Other work")
        other = self.git("rev-parse", "HEAD")
        self.git("checkout", "-q", "feature")
        for name, base, message in (
            ("missing", "no-such-ref", "does not name a commit"),
            ("head", head, "nothing to review"),
            ("not an ancestor", other, "not an ancestor"),
        ):
            with self.subTest(name):
                self.assert_refused(self.run_review(base=base), message)

    def test_intent_path_may_start_with_a_tilde(self):
        (self.home / "plan.md").write_text("# Plan\n")

        self.assert_success(self.run_review("--intent", "~/plan.md"))

        self.assertIn(str(self.home / "plan.md"), self.reviews()[0]["prompt"])

    def test_missing_intent_file_is_refused(self):
        self.assert_refused(
            self.run_review("--intent", str(self.root / "missing.md")), "not a file"
        )

    def test_dirty_checkout_is_refused(self):
        (self.repo / "app.txt").write_text("uncommitted\n")

        self.assert_refused(self.run_review(), "clean checkout")

    def test_same_range_reuses_the_review(self):
        first = self.assert_success(self.run_review())

        second = self.assert_success(self.run_review())

        self.assertEqual(second["run_id"], first["run_id"])
        self.assertEqual(len(self.reviews()), 1)

    def test_new_base_or_head_starts_a_new_review(self):
        first = self.assert_success(self.run_review())
        self.commit("fixed\n", "Fix the value")
        fix_base = self.git("rev-parse", "HEAD~1")

        second = self.assert_success(self.run_review(base=fix_base))
        third = self.assert_success(self.run_review())

        self.assertEqual(second["base_sha"], fix_base)
        self.assertEqual(len({first["run_id"], second["run_id"], third["run_id"]}), 3)

    def test_status_keeps_a_review_with_parent_fixes_fresh(self):
        reviewed = self.assert_success(self.run_review())
        (self.repo / "app.txt").write_text("fixed\n")

        state = self.output(self.invoke("status"))

        self.assertEqual(state["run_id"], reviewed["run_id"])
        self.assertFalse(state["stale"])
        self.assertTrue(state["artifact_valid"])

    def test_status_marks_a_review_stale_after_a_new_commit_or_changed_findings(self):
        reviewed = self.assert_success(self.run_review())
        Path(reviewed["findings_file"]).write_text("{}\n")

        state = self.output(self.invoke("status"))

        self.assertFalse(state["artifact_valid"])
        self.assertTrue(state["stale"])

        self.commit("fixed\n", "Fix the value")

        self.assertTrue(self.output(self.invoke("status"))["stale"])

    def test_status_reports_pending_and_interrupted(self):
        self.assertEqual(self.output(self.invoke("status"))["phase"], "pending")
        self.state_path.parent.mkdir()
        self.state_path.write_text(
            json.dumps({"phase": "running", "child_pid": 999999})
        )

        self.assertEqual(self.output(self.invoke("status"))["phase"], "interrupted")

    def test_timeout_stops_descendants(self):
        result = self.run_review("--timeout", "1", mode="descendants", timeout=20)

        self.assert_failed(result, "timed out")
        deadline = time.monotonic() + 2
        while self.descendant_alive() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.descendant_alive())

    def test_lock_prevents_overlapping_reviews(self):
        lock_path = self.repo / ".notes/go-codex-review.lock"
        lock_path.parent.mkdir()
        with lock_path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

            self.assert_refused(self.run_review(), "already running")

    def test_notes_symlink_is_refused(self):
        target = self.root / "elsewhere"
        target.mkdir()
        (self.repo / ".notes").symlink_to(target, target_is_directory=True)

        result = self.run_review()

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("symlink", result.stderr)
        self.assertEqual(list(target.iterdir()), [])


if __name__ == "__main__":
    unittest.main()
