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
import uuid


RUNNER = Path(__file__).resolve().parents[1] / "run-review.py"
PR_URL = "https://github.com/org/repo/pull/123"
SHIM = r"""
import json
import os
from pathlib import Path
import sys
import time

root = Path.cwd()
args = sys.argv[1:]
harness = Path(sys.argv[0]).name
state_path = root / ".notes/go-review-state.json"
call = {
    "harness": harness,
    "pid": os.getpid(),
    "args": args,
    "prompt": sys.stdin.read(),
    "cwd": str(root),
    "checkpoint": json.loads(state_path.read_text()) if state_path.exists() else None,
}
with open(os.environ["REVIEW_TEST_CALLS"], "a") as calls:
    calls.write(json.dumps(call) + "\n")
if os.environ.get("REVIEW_TEST_EDIT") == "yes":
    (root / "app.txt").write_text("review fix\n")
mode = os.environ.get("REVIEW_TEST_MODE", "success")
if mode == "failure":
    print("fixture harness failure", file=sys.stderr)
    sys.exit(7)
if mode == "timeout":
    time.sleep(30)
    sys.exit(0)
if mode == "empty":
    sys.exit(0)

review_file = root / ".notes/review.md"
if mode == "missing_artifact":
    review_file.unlink(missing_ok=True)
if mode not in {"missing_artifact", "stale_artifact"}:
    review_file.parent.mkdir(exist_ok=True)
    review_file.write_text("# Review\n\n## Fix Summary\n\nFixed the fixture.\n")
result = {
    "status": "blocked" if mode == "blocked" else "completed",
    "review_file": str(review_file),
    "summary": "Fixture review finished.",
}
if harness == "claude":
    if mode == "malformed":
        print("{invalid JSON")
    else:
        print(json.dumps({
            "type": "result",
            "subtype": "error_during_execution" if mode == "engine_error" else "success",
            "is_error": mode == "engine_error",
            "structured_output": result,
        }))
else:
    result_path = Path(args[args.index("--output-last-message") + 1])
    result_path.write_text("{invalid JSON" if mode == "malformed" else json.dumps(result))
    print(json.dumps({"type": "turn.failed" if mode == "engine_error" else "turn.completed"}))
"""


class RunReviewTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="go-review-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "checkout with spaces"
        self.repo.mkdir()
        self.shims = self.root / "bin"
        self.shims.mkdir()
        self.calls_file = self.root / "calls.jsonl"
        self.state_path = self.repo / ".notes/go-review-state.json"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_") and not key.startswith("REVIEW_TEST_")
        }
        self.env.update(
            {
                "PATH": f"{self.shims}:/usr/bin:/bin",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "REVIEW_TEST_CALLS": str(self.calls_file),
            }
        )
        for harness in ("claude", "codex"):
            path = self.shims / harness
            path.write_text(f"#!{sys.executable}\n" + textwrap.dedent(SHIM))
            path.chmod(0o755)
        self.git("init", "-q", "-b", "feature")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / ".git/info/exclude").write_text(".notes/\n")
        (self.repo / "app.txt").write_text("original\n")
        self.git("add", "app.txt")
        self.git("commit", "-qm", "Initial fixture")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def invoke(self, *args, mode="success", edit=False, cwd=None):
        env = dict(
            self.env, REVIEW_TEST_MODE=mode, REVIEW_TEST_EDIT="yes" if edit else "no"
        )
        return subprocess.run(
            [sys.executable, str(RUNNER), *args],
            cwd=cwd or self.repo,
            env=env,
            capture_output=True,
            text=True,
            timeout=10,
        )

    def run_review(self, harness="codex", **kwargs):
        return self.invoke("run", "--harness", harness, "--pr-url", PR_URL, **kwargs)

    def calls(self):
        if not self.calls_file.exists():
            return []
        return [json.loads(line) for line in self.calls_file.read_text().splitlines()]

    def output(self, result):
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(result.stdout)

    def state(self):
        return json.loads(self.state_path.read_text())

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr)
        state = self.output(result)
        self.assertEqual(state["phase"], "reviewed")
        self.assertEqual(state["next_action"], "validate-review-fixes")
        return state

    def test_harness_is_required_and_invalid_harness_does_not_launch(self):
        for args in (
            ("run", "--pr-url", PR_URL),
            ("run", "--harness", "unknown", "--pr-url", PR_URL),
        ):
            with self.subTest(args=args):
                self.assertNotEqual(self.invoke(*args).returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_claude_uses_fresh_print_session_and_preserves_fixes(self):
        self.assert_success(self.run_review("claude", edit=True))
        call = self.calls()[0]
        self.assertEqual(call["harness"], "claude")
        self.assertIn("-p", call["args"])
        self.assertIn("/review-code", call["prompt"])
        self.assert_fresh_invocation(call)
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def test_claude_multiline_instructions_are_not_parsed_as_skill_arguments(self):
        self.assert_success(self.run_review("claude"))
        prompt_lines = self.calls()[0]["prompt"].strip().splitlines()
        starts_with_skill = prompt_lines[0].split(maxsplit=1)[0] == "/review-code"
        self.assertFalse(
            starts_with_skill and len(prompt_lines) > 1,
            "Claude parses text after a leading slash command as skill arguments",
        )

    def test_codex_uses_fresh_exec_in_the_worktree_root(self):
        nested = self.repo / ".notes/nested"
        nested.mkdir(parents=True)
        self.assert_success(self.run_review("codex", edit=True, cwd=nested))
        call = self.calls()[0]
        self.assertEqual(call["harness"], "codex")
        self.assertIn("exec", call["args"])
        self.assertIn("$review-code", call["prompt"])
        self.assert_fresh_invocation(call)
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def assert_fresh_invocation(self, call):
        self.assertEqual(call["cwd"], str(self.repo))
        self.assertIn(PR_URL, call["prompt"])
        self.assertIn("--fix", call["prompt"])
        self.assertIn("--force", call["prompt"])
        forbidden = {
            "resume",
            "--resume",
            "--continue",
            "-c",
            "--yolo",
            "--dangerously-skip-permissions",
            "--dangerously-bypass-approvals-and-sandbox",
        }
        self.assertFalse(forbidden.intersection(call["args"]))
        self.assertEqual(len(self.calls()), 1)

    def test_running_checkpoint_exists_before_the_child_launches(self):
        parent_state = self.repo / ".notes/go-state.md"
        parent_state.parent.mkdir()
        parent_state.write_text("# /go state\nbranch: feature\n- implement: done\n")
        before = parent_state.read_bytes()
        self.assert_success(self.run_review())
        checkpoint = self.calls()[0]["checkpoint"]
        self.assertEqual(checkpoint["phase"], "running")
        self.assertEqual(checkpoint["branch"], "feature")
        self.assertEqual(checkpoint["input_sha"], self.git("rev-parse", "HEAD"))
        self.assertEqual(checkpoint["harness"], "codex")
        self.assertEqual(checkpoint["pr_url"], PR_URL)
        self.assertEqual(checkpoint["worktree"], str(self.repo))
        self.assertEqual(str(uuid.UUID(checkpoint["run_id"])), checkpoint["run_id"])
        self.assertEqual(parent_state.read_bytes(), before)
        self.assertTrue(any((self.repo / ".notes/go-reviews").iterdir()))

    def test_zero_exit_without_valid_completion_is_not_success(self):
        for harness in ("claude", "codex"):
            for mode in (
                "empty",
                "malformed",
                "blocked",
                "missing_artifact",
                "engine_error",
            ):
                with self.subTest(harness=harness, mode=mode):
                    result = self.run_review(harness, mode=mode)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.state()["phase"], "failed")
                    self.assertTrue(self.state().get("error"))

    def test_preexisting_review_artifact_is_not_completion_evidence(self):
        review = self.repo / ".notes/review.md"
        review.parent.mkdir()
        review.write_text("# Earlier review\n")
        os.utime(review, (1, 1))
        result = self.run_review(mode="stale_artifact")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.state()["phase"], "failed")

    def test_completed_review_with_known_dirty_fixes_is_reused(self):
        first = self.assert_success(self.run_review(edit=True))
        second = self.assert_success(self.run_review(edit=True))
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual(first["phase"], second["phase"])
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def test_changed_review_artifact_invalidates_cached_dirty_fixes(self):
        state = self.assert_success(self.run_review(edit=True))
        artifact = Path(state["review_file"])
        previous_stat = artifact.stat()
        artifact.write_bytes(b"x" * previous_stat.st_size)
        os.utime(artifact, ns=(previous_stat.st_atime_ns, previous_stat.st_mtime_ns))
        self.assertTrue(self.output(self.invoke("status"))["stale"])
        result = self.run_review()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def test_sigterm_records_failure_and_stops_child_without_losing_edits(self):
        env = dict(self.env, REVIEW_TEST_MODE="timeout", REVIEW_TEST_EDIT="yes")
        process = subprocess.Popen(
            [
                sys.executable,
                str(RUNNER),
                "run",
                "--harness",
                "codex",
                "--pr-url",
                PR_URL,
                "--timeout",
                "30",
            ],
            cwd=self.repo,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        child_pid = None

        def child_alive():
            if child_pid is None:
                return False
            try:
                os.kill(child_pid, 0)
                return True
            except ProcessLookupError:
                return False

        def cleanup():
            if child_alive():
                os.kill(child_pid, signal.SIGKILL)
            if process.poll() is None:
                process.kill()
            process.communicate(timeout=5)

        self.addCleanup(cleanup)
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            try:
                calls = self.calls()
                if calls:
                    child_pid = calls[0]["pid"]
                    if (self.repo / "app.txt").read_text() == "review fix\n":
                        break
            except json.JSONDecodeError:
                pass
            self.assertIsNone(process.poll(), "wrapper exited before the child started")
            time.sleep(0.02)
        else:
            self.fail(
                "child did not start and write its partial fix before the deadline"
            )

        self.assertEqual(self.state()["phase"], "running")
        process.send_signal(signal.SIGTERM)
        process.communicate(timeout=5)
        self.assertNotEqual(process.returncode, 0)
        self.assertEqual(self.state()["phase"], "failed")
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")
        deadline = time.monotonic() + 2
        while child_alive() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(
            child_alive(), "review child remained alive after wrapper termination"
        )

    def test_status_is_read_only_and_external_edits_make_review_stale(self):
        self.assert_success(self.run_review(edit=True))
        before = self.state_path.read_bytes()
        self.assertFalse(self.output(self.invoke("status")).get("stale", False))
        (self.repo / "app.txt").write_text("external edit\n")
        self.assertTrue(self.output(self.invoke("status"))["stale"])
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(len(self.calls()), 1)
        result = self.run_review()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(self.calls()), 1)
        self.assertEqual((self.repo / "app.txt").read_text(), "external edit\n")

    def test_new_head_invalidates_cache_and_launches_a_new_review(self):
        self.assert_success(self.run_review())
        self.git("commit", "-qm", "New head", "--allow-empty")
        self.assertTrue(self.output(self.invoke("status"))["stale"])
        self.assert_success(self.run_review())
        self.assertEqual(len(self.calls()), 2)

    def test_changed_branch_invalidates_cache(self):
        self.assert_success(self.run_review())
        self.git("checkout", "-qb", "another-feature")
        self.assertTrue(self.output(self.invoke("status"))["stale"])
        self.assert_success(self.run_review())
        self.assertEqual(len(self.calls()), 2)

    def test_different_harness_or_pr_cannot_reuse_a_review(self):
        self.assert_success(self.run_review("claude"))
        self.assert_success(self.run_review("codex"))
        self.assert_success(
            self.invoke(
                "run", "--harness", "codex", "--pr-url", PR_URL.replace("123", "124")
            )
        )
        self.assertEqual(
            [call["harness"] for call in self.calls()], ["claude", "codex", "codex"]
        )

    def test_failures_and_timeout_preserve_edits_and_diagnostics(self):
        for mode in ("failure", "timeout"):
            with self.subTest(mode=mode):
                self.git("checkout", "--", "app.txt")
                result = self.invoke(
                    "run",
                    "--harness",
                    "codex",
                    "--pr-url",
                    PR_URL,
                    "--timeout",
                    "1",
                    mode=mode,
                    edit=True,
                )
                self.assertNotEqual(result.returncode, 0)
                state = self.state()
                self.assertEqual(state["phase"], "failed")
                self.assertTrue(state.get("error"))
                self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")
                self.assertTrue(Path(state["log_file"]).is_file())

    def test_missing_selected_harness_does_not_fall_back(self):
        (self.shims / "codex").unlink()
        result = self.run_review("codex")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.calls(), [])

    def test_status_reports_pending_and_interrupted_without_writing_state(self):
        self.assertEqual(self.output(self.invoke("status"))["phase"], "pending")
        self.assertFalse(self.state_path.exists())
        self.run_review(mode="failure")
        state = self.state()
        state["phase"] = "running"
        self.state_path.write_text(json.dumps(state))
        before = self.state_path.read_bytes()
        self.assertEqual(self.output(self.invoke("status"))["phase"], "interrupted")
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(len(self.calls()), 1)

    def test_lock_prevents_overlapping_writers(self):
        lock_path = self.repo / ".notes/go-review.lock"
        lock_path.parent.mkdir()
        with lock_path.open("w") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            result = self.run_review()
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(self.calls(), [])
            self.assertFalse(self.state_path.exists())


if __name__ == "__main__":
    unittest.main()
