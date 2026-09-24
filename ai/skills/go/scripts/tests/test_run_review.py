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
import subprocess
import sys
import time

root = Path.cwd()
args = sys.argv[1:]
harness = Path(sys.argv[0]).name
if harness == "codex" and "--sandbox" in args and "--approve-for-me" in args:
    print("error: '--sandbox <SANDBOX_MODE>' cannot be used with '--approve-for-me'", file=sys.stderr)
    sys.exit(2)
state_path = root / ".notes/go-review-state.json"
skill_root = Path.home() / ".agents/skills/review-code"
runtime_targets = {
    "CLAUDE_SESSION_DIR": (skill_root / ".sessions", "from-child.json"),
    "REVIEW_CODE_WORKTREE_DIR": (skill_root / ".worktrees", "fixture-pr/worktree.txt"),
    "REVIEW_CODE_MARKER_DIR": (skill_root / ".sessions", ".pending-clear"),
    "REVIEW_CODE_ARTIFACTS_DIR": (skill_root / ".sessions/artifacts", "artifact.json"),
    "REVIEW_CODE_DEBUG_PATH": (Path.home() / ".cache/review-code/debug", "trace.json"),
}
runtime_files = {
    name: Path(os.environ.get(name) or default) / filename
    for name, (default, filename) in runtime_targets.items()
}
runtime_files["REVIEW_CODE_HOOK_LOG"] = Path(
    os.environ.get("REVIEW_CODE_HOOK_LOG") or skill_root / ".sessions/.session-clear-hook.log"
)
call = {
    "harness": harness,
    "pid": os.getpid(),
    "environment": {name: os.environ.get(name) for name in (
        "CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID", "CLAUDE_CONFIG_DIR",
        "CLAUDE_SESSION_DIR", "REVIEW_CODE_REVIEW_DIR", "REVIEW_CODE_WORKTREE_DIR",
        "REVIEW_CODE_MARKER_DIR", "REVIEW_CODE_HOOK_LOG", "REVIEW_CODE_ARTIFACTS_DIR",
        "REVIEW_CODE_DEBUG_PATH", "DEBUG_SESSION_DIR",
    )},
    "args": args,
    "prompt": sys.stdin.read(),
    "cwd": str(root),
    "runtime_files": {name: str(path) for name, path in runtime_files.items()},
    "runtime_state_before": {name: path.exists() for name, path in runtime_files.items()},
    "checkpoint": json.loads(state_path.read_text()) if state_path.exists() else None,
}
with open(os.environ["REVIEW_TEST_CALLS"], "a") as calls:
    calls.write(json.dumps(call) + "\n")
if os.environ.get("REVIEW_TEST_EDIT") == "yes":
    (root / "app.txt").write_text("review fix\n")
mode = os.environ.get("REVIEW_TEST_MODE", "success")
if mode in {"runtime_state", "failure_runtime"}:
    for path in runtime_files.values():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("State written by the review child.\n")
if mode in {"descendants", "descendants_success"}:
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
if mode == "change_head":
    subprocess.run(["git", "commit", "--allow-empty", "-qm", "Unexpected review commit"],
                   check=True)
if mode == "change_branch":
    subprocess.run(["git", "checkout", "-qb", "unexpected-review-branch"], check=True)
if mode in {"failure", "failure_runtime"}:
    print("fixture harness failure", file=sys.stderr)
    sys.exit(7)
if mode in {"timeout", "descendants"}:
    time.sleep(30)
    sys.exit(0)
if mode == "empty":
    sys.exit(0)

global_review_root = Path.home() / ".agents/skills/review-code/.reviews"
review_root = Path(os.environ.get("REVIEW_CODE_REVIEW_DIR") or global_review_root)
if mode == "ignores_review_override":
    review_root = global_review_root
review_file = review_root / "review.md"
if mode == "misleading_artifact":
    review_file = review_root / "unrelated-org/other-repo/pr-999.md"
if mode == "missing_artifact":
    review_file.unlink(missing_ok=True)
if mode != "missing_artifact":
    review_file.parent.mkdir(parents=True, exist_ok=True)
    review_file.write_text("# Review\n\n## Fix Summary\n\nFixed the fixture.\n")
    if mode == "stale_artifact":
        os.utime(review_file, (1, 1))
if mode == "outside_artifact":
    review_file = root / ".notes/outside.md"
    review_file.write_text("Fresh but outside the allowed review directory.\n")
elif mode == "symlink_artifact":
    link = review_file.with_name("linked-review.md")
    link.symlink_to(review_file)
    review_file = link
elif mode == "symlink_parent_artifact":
    link = review_file.parent / "linked-parent"
    link.symlink_to(root / ".notes", target_is_directory=True)
    review_file = link / "escaped-review.md"
    review_file.write_text("Fresh but outside the allowed review directory.\n")
elif mode == "directory_artifact":
    review_file = review_file.parent
elif mode == "empty_artifact":
    review_file.write_text("")
elif mode == "destination_symlink":
    destination = root / ".notes/go-reviews" / call["checkpoint"]["run_id"] / "review.md"
    destination.symlink_to(os.environ["REVIEW_TEST_PROTECTED"])
if mode.startswith("swap_"):
    directories = {
        "swap_notes": root / ".notes",
        "swap_runs": root / ".notes/go-reviews",
        "swap_attempt": root / ".notes/go-reviews" / call["checkpoint"]["run_id"],
        "swap_reviews": review_file.parent,
    }
    directory = directories[mode]
    directory.rename(directory.with_name(directory.name + "-original"))
    directory.symlink_to(os.environ["REVIEW_TEST_SWAP_ROOT"], target_is_directory=True)
result = {
    "status": "blocked" if mode == "blocked" else "completed",
    "review_file": "relative-review.md" if mode == "relative_artifact" else str(review_file),
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
        self.home = self.root / "home"
        self.review_root = self.home / ".agents/skills/review-code/.reviews"
        self.review_root.mkdir(parents=True)
        self.skill_helper = (
            self.review_root.parent / "scripts/helpers/config-helpers.sh"
        )
        self.skill_helper.parent.mkdir(parents=True)
        self.skill_helper.write_text(
            'get_review_root() { echo "${REVIEW_CODE_REVIEW_DIR:-${HOME}/.agents/skills/review-code/.reviews}"; }\n'
        )
        self.archive_file = self.review_root / "org/repo/pr-123.md"
        self.descendant_file = self.root / "descendant.pid"
        self.addCleanup(self.cleanup_descendant)
        self.protected = self.root / "protected.txt"
        self.protected.write_text("Preserve this content.\n")
        self.swap_root = self.root / "outside-workflow"
        self.swap_root.mkdir()
        for name in ("state.json", "review.md", "go-review-state.json"):
            sentinel = self.swap_root / name
            sentinel.write_text("Preserve " + name + "\n")
            future = time.time() + 3600
            os.utime(sentinel, (future, future))
        self.shims = self.root / "bin"
        self.shims.mkdir()
        self.calls_file = self.root / "calls.jsonl"
        self.state_path = self.repo / ".notes/go-review-state.json"
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "REVIEW_TEST_", "REVIEW_CODE_"))
            and key not in {"CLAUDE_SESSION_DIR", "DEBUG_SESSION_DIR"}
        }
        self.env.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.shims}:/usr/bin:/bin",
                "REVIEW_TEST_DESCENDANT": str(self.descendant_file),
                "REVIEW_TEST_PROTECTED": str(self.protected),
                "REVIEW_TEST_SWAP_ROOT": str(self.swap_root),
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

    def descendant_pid(self):
        if self.descendant_file.exists():
            return int(self.descendant_file.read_text())
        return None

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
        pid = self.descendant_pid()
        if self.descendant_alive():
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass

    def assert_descendant_stopped(self):
        pid = self.descendant_pid()
        self.assertIsNotNone(pid, "shim did not start its descendant")
        deadline = time.monotonic() + 2
        while self.descendant_alive() and time.monotonic() < deadline:
            time.sleep(0.02)
        self.assertFalse(self.descendant_alive(), "review descendant remained alive")

    def output(self, result):
        self.assertTrue(result.stdout.strip(), result.stderr)
        return json.loads(result.stdout)

    def state(self):
        return json.loads(self.state_path.read_text())

    def assert_success(self, result):
        self.assertEqual(result.returncode, 0, result.stderr or result.stdout)
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
        self.assertIn("--no-session-persistence", call["args"])
        permission_index = call["args"].index("--permission-prompts")
        self.assertEqual(call["args"][permission_index + 1], "none")
        self.assertIn("/review-code", call["prompt"])
        self.assert_fresh_invocation(call)
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def test_first_claude_review_creates_its_missing_review_cache(self):
        self.review_root.rmdir()
        self.assert_success(self.run_review("claude"))
        self.assertTrue(self.review_root.is_dir())
        self.assertEqual(len(self.calls()), 1)

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
        self.assertIn("--ephemeral", call["args"])
        self.assertIn("--approve-for-me", call["args"])
        self.assertNotIn("--sandbox", call["args"])
        self.assertIn("$review-code", call["prompt"])
        self.assert_fresh_invocation(call)
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def test_child_environment_does_not_inherit_parent_sessions(self):
        names = ("CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID")
        self.env.update({name: "fixture-parent-session" for name in names})
        self.env["CLAUDE_CONFIG_DIR"] = str(self.root / "parent-claude-config")
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                self.assert_success(self.run_review(harness))
                environment = self.calls()[-1]["environment"]
                for name in names:
                    self.assertIsNone(environment[name], name)
                if harness == "codex":
                    self.assertIsNone(environment["CLAUDE_CONFIG_DIR"])

    def test_both_harnesses_replace_inherited_runtime_paths_with_attempt_paths(self):
        directory_names = (
            "CLAUDE_SESSION_DIR",
            "REVIEW_CODE_REVIEW_DIR",
            "REVIEW_CODE_WORKTREE_DIR",
            "REVIEW_CODE_MARKER_DIR",
            "REVIEW_CODE_ARTIFACTS_DIR",
            "REVIEW_CODE_DEBUG_PATH",
        )
        names = (*directory_names, "REVIEW_CODE_HOOK_LOG", "DEBUG_SESSION_DIR")
        self.env.update(
            {name: str(self.root / "inherited state" / name) for name in names}
        )
        roots = []
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                state = self.assert_success(self.run_review(harness))
                call = self.calls()[-1]
                attempt = self.repo / ".notes/go-reviews" / state["run_id"]
                roots.append(attempt)
                environment = call["environment"]
                self.assertNotIn("--add-dir", call["args"])
                self.assertIsNone(environment["DEBUG_SESSION_DIR"])
                for name in (*directory_names, "REVIEW_CODE_HOOK_LOG"):
                    self.assertIsNotNone(environment[name], name)
                    path = Path(environment[name])
                    self.assertTrue(path.is_absolute(), name)
                    self.assertTrue(path.is_relative_to(attempt), name)
                    self.assertNotEqual(path, attempt, name)
                self.assertEqual(
                    len({environment[name] for name in directory_names[:3]}), 3
                )
        self.assertEqual(len(roots), 2)
        self.assertNotEqual(roots[0], roots[1])

    def test_archive_target_comes_from_pr_url_and_retains_local_review(self):
        state = self.assert_success(self.run_review(mode="misleading_artifact"))
        local_review = Path(state["review_file"])
        attempt = self.repo / ".notes/go-reviews" / state["run_id"]
        self.assertTrue(local_review.is_relative_to(attempt))
        self.assertEqual(state["archive_review_file"], str(self.archive_file))
        self.assertEqual(self.archive_file.read_bytes(), local_review.read_bytes())
        self.assertFalse((self.review_root / "unrelated-org").exists())

    def use_legacy_claude_skill(self):
        legacy_skill = self.home / ".claude/skills/review-code"
        legacy_skill.parent.mkdir(parents=True)
        self.review_root.parent.rename(legacy_skill)
        self.review_root = legacy_skill / ".reviews"
        self.skill_helper = legacy_skill / "scripts/helpers/config-helpers.sh"
        self.archive_file = self.review_root / "org/repo/pr-123.md"
        self.assertFalse((self.home / ".agents/skills/review-code").exists())

    def distinct_claude_skill(self, supported=True):
        skill = self.home / ".claude/skills/review-code"
        helper = skill / "scripts/helpers/config-helpers.sh"
        helper.parent.mkdir(parents=True)
        review_root = skill / ".reviews"
        target = (
            f"${{REVIEW_CODE_REVIEW_DIR:-{review_root}}}"
            if supported
            else str(review_root)
        )
        helper.write_text(f'get_review_root() {{ echo "{target}"; }}\n')
        return skill

    def test_claude_prefers_its_installation_when_both_exist(self):
        skill = self.distinct_claude_skill()
        state = self.assert_success(self.run_review("claude"))
        self.assertEqual(
            state["archive_review_file"],
            str(skill / ".reviews/org/repo/pr-123.md"),
        )
        self.assertFalse(self.archive_file.exists())

    def test_old_claude_installation_cannot_pass_codex_preflight(self):
        self.distinct_claude_skill(supported=False)
        result = self.run_review("claude")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertIn("review-code", self.state()["error"])
        self.assertEqual(self.calls(), [])

    def test_claude_legacy_installation_passes_review_root_preflight(self):
        self.use_legacy_claude_skill()

        self.assert_success(self.run_review("claude"))

        self.assertEqual(len(self.calls()), 1)

    def test_claude_legacy_installation_archives_in_its_review_root(self):
        self.use_legacy_claude_skill()

        state = self.assert_success(self.run_review("claude"))

        self.assertEqual(state["archive_review_file"], str(self.archive_file))
        self.assertEqual(
            self.archive_file.read_bytes(), Path(state["review_file"]).read_bytes()
        )
        self.assertFalse((self.home / ".agents/skills/review-code").exists())

    def test_old_installed_skill_fails_before_launch(self):
        self.skill_helper.write_text(
            'get_review_root() { echo "${HOME}/.agents/skills/review-code/.reviews"; }\n'
        )
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                result = self.run_review(harness)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertIn("review-code", self.state()["error"])
                self.assertEqual(self.calls(), [])
                self.assertFalse(self.archive_file.exists())

    def test_child_ignoring_override_cannot_publish_its_global_artifact(self):
        for harness in ("claude", "codex"):
            with self.subTest(harness=harness):
                result = self.run_review(harness, mode="ignores_review_override")
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.state()["phase"], "failed")
                self.assertFalse(self.archive_file.exists())

    def write_global_sentinels(self):
        skill = self.review_root.parent
        sentinels = (
            self.archive_file,
            self.review_root / "unrelated/other-repo/pr-999.md",
            self.review_root / "token-usage.jsonl",
            skill / ".sessions/from-child.json",
            skill / ".sessions/.pending-clear",
            skill / ".sessions/.session-clear-hook.log",
            skill / ".sessions/artifacts/artifact.json",
            skill / ".worktrees/fixture-pr/worktree.txt",
            self.home / ".cache/review-code/debug/trace.json",
        )
        for path in sentinels:
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(f"Preserve {path.relative_to(self.home)}\n")

    def global_files(self):
        return {
            str(path.relative_to(self.home)): path.read_bytes()
            for path in self.home.rglob("*")
            if path.is_file()
        }

    def test_runtime_state_is_fresh_and_only_the_intended_report_is_archived(self):
        self.write_global_sentinels()
        expected = self.global_files()
        attempts = []
        for index, harness in enumerate(("claude", "claude", "codex", "codex")):
            with self.subTest(harness=harness, attempt=index):
                self.git("commit", "--allow-empty", "-qm", f"Review attempt {index}")
                state = self.assert_success(
                    self.run_review(harness, mode="runtime_state")
                )
                expected[str(self.archive_file.relative_to(self.home))] = Path(
                    state["review_file"]
                ).read_bytes()
                self.assertEqual(self.global_files(), expected)
                call = self.calls()[-1]
                self.assertFalse(any(call["runtime_state_before"].values()))
                attempt = self.repo / ".notes/go-reviews" / state["run_id"]
                attempts.append(attempt)
                for path in map(Path, call["runtime_files"].values()):
                    self.assertTrue(path.is_relative_to(attempt))
                    self.assertEqual(
                        path.read_text(), "State written by the review child.\n"
                    )
        self.assertEqual(len(set(attempts)), 4)

    def test_failed_or_invalid_attempts_preserve_global_history(self):
        self.write_global_sentinels()
        before = self.global_files()
        for harness in ("claude", "codex"):
            for mode in (
                "failure_runtime",
                "outside_artifact",
                "symlink_artifact",
                "relative_artifact",
                "blocked",
                "change_head",
                "change_branch",
            ):
                with self.subTest(harness=harness, mode=mode):
                    if (
                        mode == "change_branch"
                        and "unexpected-review-branch" in self.git("branch", "--list")
                    ):
                        self.git("branch", "-D", "unexpected-review-branch")
                    result = self.run_review(harness, mode=mode)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertEqual(self.state()["phase"], "failed")
                    self.assertEqual(self.global_files(), before)
                    self.git("checkout", "feature")

    def test_archive_parent_symlink_cannot_redirect_publication(self):
        (self.review_root / "org").symlink_to(self.swap_root, target_is_directory=True)
        before = {path.name: path.read_bytes() for path in self.swap_root.iterdir()}

        result = self.run_review()

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.state()["phase"], "failed")
        self.assertEqual(
            {path.name: path.read_bytes() for path in self.swap_root.iterdir()}, before
        )

    def test_archive_leaf_symlink_cannot_overwrite_its_target(self):
        self.archive_file.parent.mkdir(parents=True)
        self.archive_file.symlink_to(self.protected)

        result = self.run_review()

        self.assertEqual(self.protected.read_text(), "Preserve this content.\n")
        if result.returncode == 0:
            state = self.assert_success(result)
            self.assertFalse(self.archive_file.is_symlink())
            self.assertEqual(
                self.archive_file.read_bytes(), Path(state["review_file"]).read_bytes()
            )
        else:
            self.assertEqual(self.state()["phase"], "failed")

    def test_child_cannot_complete_after_changing_head_or_branch(self):
        for mode in ("change_head", "change_branch"):
            with self.subTest(mode=mode):
                result = self.run_review(mode=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.state()["phase"], "failed")
                self.assertTrue(self.state()["error"])

    def test_invalid_review_artifact_paths_are_rejected(self):
        for mode in (
            "relative_artifact",
            "directory_artifact",
            "empty_artifact",
            "outside_artifact",
            "symlink_artifact",
            "symlink_parent_artifact",
        ):
            with self.subTest(mode=mode):
                self.state_path.unlink(missing_ok=True)
                result = self.run_review(mode=mode)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertEqual(self.state()["phase"], "failed")
                self.assertTrue(Path(self.state()["log_file"]).is_file())

    def test_artifact_copy_does_not_follow_a_destination_symlink(self):
        result = self.run_review(mode="destination_symlink")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.state()["phase"], "failed")
        self.assertEqual(self.protected.read_text(), "Preserve this content.\n")

    def test_preexisting_notes_symlink_cannot_redirect_lock_or_state_writes(self):
        notes = self.repo / ".notes"
        notes.symlink_to(self.swap_root, target_is_directory=True)
        before = {path.name: path.read_bytes() for path in self.swap_root.iterdir()}

        result = self.run_review()

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertEqual(
            {path.name: path.read_bytes() for path in self.swap_root.iterdir()}, before
        )
        self.assertFalse((self.swap_root / "go-review.lock").exists())

    def test_state_save_does_not_follow_an_existing_temporary_symlink(self):
        temporary = self.repo / ".notes/go-review-state.tmp"
        temporary.parent.mkdir()
        temporary.symlink_to(self.protected)
        self.assert_success(self.run_review())
        self.assertEqual(self.protected.read_text(), "Preserve this content.\n")

    def assert_directory_swap_rejected(self, mode):
        before = {path.name: path.read_bytes() for path in self.swap_root.iterdir()}
        result = self.run_review("claude", mode=mode)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.output(result)["phase"], "failed")
        after = {path.name: path.read_bytes() for path in self.swap_root.iterdir()}
        self.assertEqual(after, before)

    def test_notes_directory_swap_cannot_redirect_state_writes(self):
        self.assert_directory_swap_rejected("swap_notes")

    def test_runs_directory_swap_cannot_redirect_state_writes(self):
        self.assert_directory_swap_rejected("swap_runs")

    def test_attempt_directory_swap_cannot_redirect_state_writes(self):
        self.assert_directory_swap_rejected("swap_attempt")

    def test_review_root_swap_cannot_supply_a_completed_review(self):
        self.assert_directory_swap_rejected("swap_reviews")

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
        review = self.review_root / "review.md"
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

    def test_cached_review_symlink_is_stale_even_with_matching_bytes(self):
        state = self.assert_success(self.run_review(edit=True))
        artifact = Path(state["review_file"])
        outside = self.swap_root / "same-review.md"
        outside.write_bytes(artifact.read_bytes())
        artifact.unlink()
        artifact.symlink_to(outside)
        self.assertTrue(self.output(self.invoke("status"))["stale"])
        result = self.run_review()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_cached_review_outside_its_attempt_is_stale(self):
        state = self.assert_success(self.run_review(edit=True))
        outside = self.swap_root / "same-review.md"
        outside.write_bytes(Path(state["review_file"]).read_bytes())
        state["review_file"] = str(outside)
        self.state_path.write_text(json.dumps(state))
        self.assertTrue(self.output(self.invoke("status"))["stale"])
        result = self.run_review()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.calls()), 1)

    def test_sigterm_records_failure_and_stops_child_without_losing_edits(self):
        env = dict(self.env, REVIEW_TEST_MODE="descendants", REVIEW_TEST_EDIT="yes")
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
                    if (
                        self.repo / "app.txt"
                    ).read_text() == "review fix\n" and self.descendant_file.exists():
                        break
            except json.JSONDecodeError:
                pass
            self.assertIsNone(process.poll(), "wrapper exited before the child started")
            time.sleep(0.02)
        else:
            self.fail(
                "child did not start and write its partial fix before the deadline"
            )

        before = self.state_path.read_bytes()
        self.assertEqual(self.output(self.invoke("status"))["phase"], "running")
        self.assertEqual(self.state_path.read_bytes(), before)
        self.assertEqual(len(self.calls()), 1)
        self.assertTrue(self.descendant_alive())
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
        self.assert_descendant_stopped()

    def test_timeout_stops_descendants_that_ignore_sigterm(self):
        result = self.invoke(
            "run",
            "--harness",
            "codex",
            "--pr-url",
            PR_URL,
            "--timeout",
            "1",
            mode="descendants",
            edit=True,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.state()["phase"], "failed")
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")
        self.assert_descendant_stopped()

    def test_success_stops_descendants_before_trusting_completion(self):
        self.assert_success(self.run_review(mode="descendants_success"))
        self.assert_descendant_stopped()

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
