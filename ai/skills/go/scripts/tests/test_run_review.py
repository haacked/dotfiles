from datetime import datetime, timedelta, timezone
import fcntl
import json
import os
from pathlib import Path
import shlex
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
# A claude login pairs oauthAccount.accountUuid with oauthAccount.organizationUuid.
TEAM_LOGIN = (
    "11111111-1111-4111-8111-111111111111",
    "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
)
TEAM_USER_IN_ANOTHER_ORG = (TEAM_LOGIN[0], "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb")
TEAM_COLLEAGUE = ("33333333-3333-4333-8333-333333333333", TEAM_LOGIN[1])
PERSONAL_LOGIN = (
    "22222222-2222-4222-8222-222222222222",
    "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
)
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
limit_reports = {
    "usage_limit": {
        "subtype": "success",
        "result": "You've hit your session limit · resets 3:45pm",
    },
    "usage_limit_errors": {
        "subtype": "error_during_execution",
        "errors": ["API request failed", "Your org is out of usage · contact your admin"],
    },
}
if mode in limit_reports and os.environ.get("CLAUDE_CONFIG_DIR", "") in json.loads(
    os.environ["REVIEW_TEST_LIMITED_CONFIG_DIRS"]
):
    print(json.dumps({"type": "result", "is_error": True, **limit_reports[mode]}))
    sys.exit(1)
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
elif mode in {"append_seed", "untouched_seed"}:
    review_file = review_root / "org/repo/pr-123.md"
    if mode == "append_seed":
        with review_file.open("a") as handle:
            handle.write("\n## Second review\n\nAppended by the fixture.\n")
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
    "summary": (
        "You've hit your weekly limit · resets Mon 12:00am"
        if mode == "limit_prose"
        else "Fixture review finished."
    ),
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
            and key
            not in {
                "CLAUDE_SESSION_DIR",
                "DEBUG_SESSION_DIR",
                "CLAUDE_CONFIG_DIR",
                "DOCKET_HOME",
            }
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

    def run_review(self, harness="codex", *extra, pr_url=PR_URL, **kwargs):
        return self.invoke(
            "run", "--harness", harness, "--pr-url", pr_url, *extra, **kwargs
        )

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
        self.assertIn("run_in_background set to false", call["prompt"])
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
        self.assertNotIn("run_in_background", call["prompt"])
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
                else:
                    self.assertEqual(
                        environment["CLAUDE_CONFIG_DIR"], self.env["CLAUDE_CONFIG_DIR"]
                    )

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
            self.assert_refused(self.run_review())

    def sign_in(self, config=None, login=None):
        """Signs config in and links review-code into it. None is claude's default account.

        login is the (accountUuid, organizationUuid) pair to sign in as.
        """
        account = config / ".claude.json" if config else self.home / ".claude.json"
        skills = (config or self.home / ".claude") / "skills"
        skills.mkdir(parents=True)
        oauth = {"emailAddress": "team@example.com", "organizationName": "Team"}
        if login:
            oauth.update(accountUuid=login[0], organizationUuid=login[1])
        account.write_text(json.dumps({"oauthAccount": oauth}))
        (skills / "review-code").symlink_to(
            self.review_root.parent, target_is_directory=True
        )
        return config

    def write_docket_config(self, primary, *fallbacks, home=None):
        home = home or self.home / ".docket"
        home.mkdir(parents=True, exist_ok=True)
        lines = ['github_user = "fixture"']
        if primary is not None:
            lines.append(f"claude_config_dir = {json.dumps(str(primary))}")
        lines.append(
            f"claude_fallback_config_dirs = {json.dumps([str(d) for d in fallbacks])}"
        )
        (home / "config.toml").write_text("\n".join(lines) + "\n")
        return home / "config.toml"

    def use_team_config(self, path=None):
        return self.use_accounts(path or "team config")[0]

    def use_accounts(self, *names):
        accounts = [self.sign_in(self.root / name) for name in names]
        self.write_docket_config(*accounts)
        return accounts

    def record_limit(self, account, at, until, home=None, login=None):
        """Appends a limit the way docket writes it, with times relative to now.

        login is the (accountUuid, organizationUuid) pair that account was signed in to.
        """
        now = datetime.now(timezone.utc)
        reset = now + until
        limits = (home or self.home / ".docket") / "limits.jsonl"
        limits.parent.mkdir(parents=True, exist_ok=True)
        entry = {
            "account": str(account),
            "at": (now + at).strftime("%Y-%m-%dT%H:%M:%S.%f123Z"),
            "until": reset.astimezone(timezone(timedelta(hours=-7))).isoformat(),
        }
        if login:
            entry["login"] = {"account_uuid": login[0], "organization_uuid": login[1]}
        with limits.open("a") as handle:
            handle.write(json.dumps(entry) + "\n")
        return reset

    def limit_config_dirs(self, *config_dirs):
        self.env["REVIEW_TEST_LIMITED_CONFIG_DIRS"] = json.dumps(
            [str(path) for path in config_dirs]
        )

    def child_config_dirs(self):
        return [call["environment"]["CLAUDE_CONFIG_DIR"] for call in self.calls()]

    def assert_not_launched(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls(), [])
        state = self.state()
        self.assertEqual(state["phase"], "failed")
        return state

    def assert_refused(self, result):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.calls(), [])
        self.assertFalse(self.state_path.exists())
        return result.stderr

    def assert_usage_limit_failure(self, result, calls):
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(len(self.calls()), calls)
        state = self.state()
        self.assertEqual(state["phase"], "failed")
        self.assertIn("usage limit", state["error"])

    def test_claude_review_without_docket_config_runs_on_the_parent_account(self):
        parent = str(self.root / "parent config")
        self.env["CLAUDE_CONFIG_DIR"] = parent

        state = self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [parent])
        self.assertEqual(state["claude_config_dir"], parent)

    def test_limits_without_docket_config_do_not_block_the_parent_account(self):
        self.record_limit("", -timedelta(hours=1), timedelta(days=1))

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [None])

    def test_claude_state_records_null_config_dir_when_child_has_none(self):
        state = self.assert_success(self.run_review("claude"))

        self.assertIsNone(state.get("claude_config_dir", "missing"))

    def test_docket_config_without_claude_config_dir_starts_on_the_parent_account(self):
        parent = str(self.root / "parent config")
        self.env["CLAUDE_CONFIG_DIR"] = parent
        backup = self.sign_in(self.root / "backup")
        self.write_docket_config(None, backup)
        self.limit_config_dirs(parent)

        self.assert_success(self.run_review("claude", mode="usage_limit"))

        self.assertEqual(self.child_config_dirs(), [parent, str(backup)])

    def test_relative_docket_account_fails_before_launch(self):
        absolute = self.root / "absolute"
        for primary, fallbacks in (("team config", []), (absolute, ["backup"])):
            with self.subTest(primary=primary, fallbacks=fallbacks):
                config = self.write_docket_config(primary, *fallbacks)

                stderr = self.assert_refused(self.run_review("claude"))

                self.assertIn(str(config), stderr)
                self.assertIn("relative", stderr)

    def test_unreadable_docket_config_fails_before_launch(self):
        config = self.home / ".docket/config.toml"
        config.parent.mkdir(parents=True)
        for name, contents in (
            ("invalid TOML", "claude_config_dir = "),
            ("account not a string", "claude_config_dir = 3"),
            ("fallbacks not a list", 'claude_fallback_config_dirs = "/backup"'),
            ("fallback not a string", "claude_fallback_config_dirs = [3]"),
        ):
            with self.subTest(name):
                config.write_text(contents + "\n")

                stderr = self.assert_refused(self.run_review("claude"))

                self.assertIn(str(config), stderr)

    def test_docket_account_without_sign_in_fails_before_launch(self):
        config = self.use_team_config()
        account = config / ".claude.json"
        for name, contents in (
            ("missing", None),
            ("invalid JSON", "{invalid JSON"),
            ("not an object", "[]"),
            ("no account", "{}"),
            ("null account", '{"oauthAccount": null}'),
        ):
            with self.subTest(name):
                account.unlink(missing_ok=True)
                if contents is not None:
                    account.write_text(contents)

                state = self.assert_not_launched(self.run_review("claude"))

                for hint in (
                    str(self.home / ".docket/config.toml"),
                    f"CLAUDE_CONFIG_DIR={shlex.quote(str(config))} claude",
                    "/login",
                ):
                    self.assertIn(hint, state["error"])

    def test_docket_account_without_review_skill_fails_before_launch(self):
        config = self.use_team_config()
        (config / "skills/review-code").unlink()

        state = self.assert_not_launched(self.run_review("claude"))

        self.assertIn(str(config / "skills"), state["error"])

    def test_default_account_without_sign_in_fails_before_its_launch(self):
        self.env["CLAUDE_CONFIG_DIR"] = str(self.root / "parent config")
        config = self.use_team_config()
        self.write_docket_config(config, self.home / ".claude")
        self.limit_config_dirs(config)

        result = self.run_review("claude", mode="usage_limit")

        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.child_config_dirs(), [str(config)])
        self.assertIn("not signed in", self.state()["error"])
        self.assertIn("`claude`", self.state()["error"])

    def test_claude_child_runs_on_the_docket_account(self):
        self.env["CLAUDE_CONFIG_DIR"] = str(self.root / "parent config")
        config = self.use_team_config()

        state = self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(config)])
        self.assertEqual(state["claude_config_dir"], str(config))

    def test_docket_account_expands_home(self):
        config = self.use_team_config(self.home / "team config")
        self.write_docket_config("~/team config")

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(config)])

    def test_docket_home_setting_locates_the_config_and_limits(self):
        docket = self.root / "docket home"
        self.env["DOCKET_HOME"] = str(docket)
        primary = self.sign_in(self.root / "primary")
        backup = self.sign_in(self.root / "backup")
        self.write_docket_config(primary, backup, home=docket)
        self.record_limit(primary, -timedelta(hours=1), timedelta(days=1), home=docket)

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(backup)])

    def test_codex_ignores_the_docket_accounts(self):
        config = self.use_team_config()
        (config / ".claude.json").unlink()

        self.assert_success(self.run_review("codex"))

        self.assertEqual(self.child_config_dirs(), [None])

    def test_usage_limit_moves_through_the_docket_accounts_in_order(self):
        primary, backup, spare = self.use_accounts("primary", "backup", "spare")
        self.env["CLAUDE_CONFIG_DIR"] = str(spare)
        self.limit_config_dirs(primary, backup)

        state = self.assert_success(self.run_review("claude", mode="usage_limit"))

        self.assertEqual(
            self.child_config_dirs(), [str(primary), str(backup), str(spare)]
        )
        self.assertEqual(state["claude_config_dir"], str(spare))
        backup_run_id = self.calls()[1]["checkpoint"]["run_id"]
        self.assertEqual(state["fallback_from_run_id"], backup_run_id)
        limited = json.loads(
            (self.repo / ".notes/go-reviews" / backup_run_id / "state.json").read_text()
        )
        self.assertEqual(limited["phase"], "failed")
        self.assertIn("usage limit", limited["error"])

    def test_usage_limit_on_every_docket_account_falls_back_to_the_parent_account(self):
        parent = self.root / "parent config"
        self.env["CLAUDE_CONFIG_DIR"] = str(parent)
        primary, backup = self.use_accounts("primary", "backup")
        self.limit_config_dirs(primary, backup)

        self.assert_success(self.run_review("claude", mode="usage_limit"))

        self.assertEqual(
            self.child_config_dirs(), [str(primary), str(backup), str(parent)]
        )

    def test_usage_limit_on_every_account_fails_after_the_parent_account(self):
        self.limit_config_dirs(*self.use_accounts("primary", "backup"), "")

        result = self.run_review("claude", mode="usage_limit_errors")

        self.assert_usage_limit_failure(result, calls=3)

    def test_docket_spellings_of_the_default_account_run_without_a_config_dir(self):
        parent = self.root / "parent config"
        self.env["CLAUDE_CONFIG_DIR"] = str(parent)
        config = self.use_team_config()
        self.sign_in()
        tilde = os.path.join("~", ".claude")
        self.write_docket_config(config, tilde, f"{self.home}/.claude/")
        self.limit_config_dirs(config, "")

        self.assert_success(self.run_review("claude", mode="usage_limit"))

        self.assertEqual(self.child_config_dirs(), [str(config), None, str(parent)])

    def test_session_spelling_of_the_default_dir_is_a_separate_account(self):
        session = f"{self.home}/.claude"
        self.env["CLAUDE_CONFIG_DIR"] = session
        config = self.use_team_config()
        self.sign_in()
        self.write_docket_config(config, os.path.join("~", ".claude"))
        self.limit_config_dirs(config, "")

        self.assert_success(self.run_review("claude", mode="usage_limit"))

        self.assertEqual(self.child_config_dirs(), [str(config), None, session])

    def test_usage_limit_after_review_edits_fails_without_fallback(self):
        self.limit_config_dirs(self.use_team_config())

        result = self.run_review("claude", mode="usage_limit", edit=True)

        self.assert_usage_limit_failure(result, calls=1)
        self.assertEqual((self.repo / "app.txt").read_text(), "review fix\n")

    def test_status_reports_running_while_a_fallback_attempt_can_start(self):
        self.limit_config_dirs(self.use_team_config(), "")
        self.run_review("claude", mode="usage_limit")
        self.assertEqual(self.output(self.invoke("status"))["phase"], "failed")

        with (self.repo / ".notes/go-review.lock").open("a") as lock:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

            self.assertEqual(self.output(self.invoke("status"))["phase"], "running")

    def test_usage_limit_does_not_fall_back_to_the_same_account(self):
        config = self.use_team_config()
        self.env["CLAUDE_CONFIG_DIR"] = str(config)
        self.limit_config_dirs(config)

        result = self.run_review("claude", mode="usage_limit")

        self.assert_usage_limit_failure(result, calls=1)

    def test_usage_limit_without_docket_config_fails_without_fallback(self):
        self.limit_config_dirs("")

        result = self.run_review("claude", mode="usage_limit")

        self.assert_usage_limit_failure(result, calls=1)

    def test_account_over_a_recorded_limit_is_skipped(self):
        primary, backup = self.use_accounts("primary", "backup")
        self.record_limit(primary, -timedelta(hours=1), timedelta(days=1))

        state = self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(backup)])
        self.assertNotIn("fallback_from_run_id", state)

    def test_rotation_stays_on_the_backup_after_the_primary_limit_resets(self):
        primary, backup = self.use_accounts("primary", "backup")
        self.record_limit(primary, -timedelta(days=2), -timedelta(hours=1))

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(backup)])

    def test_rotation_wraps_to_an_account_whose_limit_reset(self):
        primary, backup = self.use_accounts("primary", "backup")
        self.record_limit(backup, -timedelta(days=1), timedelta(days=1))
        self.record_limit(primary, -timedelta(days=3), -timedelta(days=2))

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(primary)])

    def test_every_account_over_a_recorded_limit_falls_back_to_the_parent_account(self):
        parent = self.root / "parent config"
        self.env["CLAUDE_CONFIG_DIR"] = str(parent)
        for account in self.use_accounts("primary", "backup"):
            self.record_limit(account, -timedelta(hours=1), timedelta(days=1))

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(parent)])

    def test_every_account_over_a_recorded_limit_fails_before_launch(self):
        primary, backup = self.use_accounts("primary", "backup")
        self.env["CLAUDE_CONFIG_DIR"] = str(backup)
        self.record_limit(primary, -timedelta(hours=2), timedelta(days=2))
        reset = self.record_limit(backup, -timedelta(hours=1), timedelta(hours=5))

        stderr = self.assert_refused(self.run_review("claude"))

        self.assertIn("usage limit", stderr)
        self.assertIn(reset.astimezone().isoformat(timespec="minutes"), stderr)

    def test_accounts_reports_the_rotation_limits_and_review_order(self):
        primary, backup = self.use_accounts("primary", "backup")
        reset = self.record_limit(primary, -timedelta(hours=1), timedelta(hours=5))
        self.record_limit(backup, -timedelta(days=3), -timedelta(days=2))

        result = self.invoke("accounts", cwd=self.root)

        self.assertEqual(result.returncode, 0, result.stderr)
        report = json.loads(result.stdout)
        self.assertEqual(report["rotation"], [str(primary), str(backup)])
        self.assertEqual(report["order"], [str(backup), ""])
        self.assertEqual(list(report["limits"]), [str(primary)])
        self.assertEqual(datetime.fromisoformat(report["limits"][str(primary)]), reset)
        self.assertEqual(self.calls(), [])

    def test_accounts_reports_an_unreadable_docket_config(self):
        self.write_docket_config("relative/account")

        result = self.invoke("accounts", cwd=self.root)

        self.assertEqual(result.returncode, 1)
        self.assertIn("relative", result.stderr)
        self.assertEqual(result.stdout, "")

    def test_unparseable_limits_and_unlisted_accounts_count_for_nothing(self):
        primary, _backup = self.use_accounts("primary", "backup")
        self.record_limit(
            self.root / "unlisted", -timedelta(minutes=1), timedelta(days=1)
        )
        with (self.home / ".docket/limits.jsonl").open("a") as handle:
            for line in (
                "{invalid JSON",
                json.dumps([str(primary)]),
                json.dumps(
                    {"account": str(primary), "at": "yesterday", "until": "soon"}
                ),
                json.dumps({"account": 3, "at": "2026-01-01T00:00:00Z"}),
            ):
                handle.write(line + "\n")

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(primary)])

    def test_accounts_reports_every_rotation_dir_signed_in_to_a_limited_login(self):
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        backup = self.sign_in(self.root / "backup", TEAM_LOGIN)
        spare = self.sign_in(self.root / "spare", PERSONAL_LOGIN)
        self.write_docket_config(primary, backup, spare)
        reset = self.record_limit(
            primary, -timedelta(hours=1), timedelta(hours=5), login=TEAM_LOGIN
        )

        report = self.output(self.invoke("accounts", cwd=self.root))

        self.assertEqual(
            {
                account: datetime.fromisoformat(until)
                for account, until in report["limits"].items()
            },
            {str(primary): reset, str(backup): reset},
        )
        self.assertEqual(report["order"], [str(spare), ""])

    def test_limit_on_one_dir_skips_another_dir_signed_in_to_the_same_login(self):
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        backup = self.sign_in(self.root / "backup", TEAM_LOGIN)
        spare = self.sign_in(self.root / "spare", PERSONAL_LOGIN)
        self.write_docket_config(primary, backup, spare)
        self.record_limit(
            primary, -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN
        )

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(spare)])

    def test_limit_recorded_outside_the_rotation_blocks_a_dir_signed_in_to_its_login(
        self,
    ):
        parent = self.root / "parent config"
        self.env["CLAUDE_CONFIG_DIR"] = str(parent)
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        backup = self.sign_in(self.root / "backup", PERSONAL_LOGIN)
        self.write_docket_config(primary, backup)
        self.record_limit("", -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN)

        report = self.output(self.invoke("accounts", cwd=self.root))

        self.assertEqual(list(report["limits"]), [str(primary)])
        self.assertEqual(report["order"], [str(backup), str(parent)])

    def test_limit_does_not_block_its_dir_once_the_dir_signs_in_to_another_login(self):
        primary = self.sign_in(self.root / "primary", PERSONAL_LOGIN)
        self.write_docket_config(primary, self.sign_in(self.root / "backup"))
        self.record_limit(
            primary, -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN
        )

        self.assert_success(self.run_review("claude"))

        self.assertEqual(self.child_config_dirs(), [str(primary)])

    def test_limit_without_a_login_blocks_only_its_own_dir(self):
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        backup = self.sign_in(self.root / "backup", TEAM_LOGIN)
        self.write_docket_config(primary, backup)
        self.record_limit(primary, -timedelta(hours=1), timedelta(days=1))

        report = self.output(self.invoke("accounts", cwd=self.root))

        self.assertEqual(list(report["limits"]), [str(primary)])

    def test_limit_with_a_partial_or_null_login_blocks_only_its_own_dir(self):
        for name, recorded in (
            ("null UUIDs", {"account_uuid": None, "organization_uuid": None}),
            ("only an account UUID", {"account_uuid": TEAM_LOGIN[0]}),
        ):
            with self.subTest(name):
                primary = self.sign_in(self.root / name / "primary", TEAM_LOGIN)
                backup = self.sign_in(self.root / name / "backup", TEAM_LOGIN)
                self.write_docket_config(primary, backup)
                limits = self.home / ".docket/limits.jsonl"
                limits.write_text(
                    json.dumps(
                        {
                            "account": str(primary),
                            "login": recorded,
                            "at": "2026-01-01T00:00:00Z",
                            "until": "2099-01-01T00:00:00Z",
                        }
                    )
                    + "\n"
                )

                report = self.output(self.invoke("accounts", cwd=self.root))

                self.assertEqual(list(report["limits"]), [str(primary)])

    def test_dir_without_both_uuids_has_no_known_login(self):
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        backup = self.sign_in(self.root / "backup", TEAM_LOGIN)
        self.write_docket_config(primary, backup)
        # Without a known login, only the limit's account blocks a dir.
        self.record_limit(
            primary, -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN
        )
        oauth = json.loads((primary / ".claude.json").read_text())["oauthAccount"]
        for name, contents in (
            ("missing", None),
            ("invalid JSON", "{invalid JSON"),
            ("no accountUuid", {k: v for k, v in oauth.items() if k != "accountUuid"}),
            (
                "no organizationUuid",
                {k: v for k, v in oauth.items() if k != "organizationUuid"},
            ),
            ("null accountUuid", dict(oauth, accountUuid=None)),
            ("null organizationUuid", dict(oauth, organizationUuid=None)),
        ):
            with self.subTest(name):
                for config in (primary, backup):
                    login = config / ".claude.json"
                    login.unlink(missing_ok=True)
                    if isinstance(contents, str):
                        login.write_text(contents)
                    elif contents is not None:
                        login.write_text(json.dumps({"oauthAccount": contents}))

                report = self.output(self.invoke("accounts", cwd=self.root))

                self.assertEqual(list(report["limits"]), [str(primary)])

    def test_rotation_starts_after_the_first_dir_the_latest_limit_applies_to(self):
        primary = self.sign_in(self.root / "primary")
        backup = self.sign_in(self.root / "backup", TEAM_LOGIN)
        spare = self.sign_in(self.root / "spare", TEAM_LOGIN)
        self.write_docket_config(primary, backup, spare)
        self.record_limit(
            spare, -timedelta(days=2), -timedelta(days=1), login=TEAM_LOGIN
        )

        report = self.output(self.invoke("accounts", cwd=self.root))

        # The start passes every dir on the limited login.
        self.assertEqual(report["order"], [str(primary), str(backup), ""])

    def test_rotation_stays_off_a_login_after_its_limit_resets(self):
        first = self.sign_in(self.root / "first", TEAM_LOGIN)
        second = self.sign_in(self.root / "second", TEAM_LOGIN)
        other = self.sign_in(self.root / "other", PERSONAL_LOGIN)
        self.write_docket_config(first, second, other)
        self.record_limit(
            second, -timedelta(days=2), -timedelta(days=1), login=TEAM_LOGIN
        )

        report = self.output(self.invoke("accounts", cwd=self.root))

        self.assertEqual(report["order"][0], str(other))

    def test_limit_on_a_rotation_login_leaves_out_the_session_account_on_it(self):
        self.sign_in(None, TEAM_LOGIN)
        team = self.sign_in(self.root / "team", TEAM_LOGIN)
        spare = self.sign_in(self.root / "spare", PERSONAL_LOGIN)
        self.write_docket_config(team, spare)
        self.record_limit(
            team, -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN
        )

        report = self.output(self.invoke("accounts", cwd=self.root))

        self.assertEqual(report["order"], [str(spare)])

    def test_every_login_over_a_limit_refuses_instead_of_the_session_account(self):
        self.sign_in(None, TEAM_LOGIN)
        team = self.sign_in(self.root / "team", TEAM_LOGIN)
        spare = self.sign_in(self.root / "spare", PERSONAL_LOGIN)
        self.write_docket_config(team, spare)
        self.record_limit(
            team, -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN
        )
        self.record_limit(
            spare, -timedelta(hours=1), timedelta(days=1), login=PERSONAL_LOGIN
        )

        stderr = self.assert_refused(self.run_review("claude"))

        self.assertIn("usage limit", stderr)

    def test_latest_limit_that_applies_to_no_rotation_dir_leaves_the_start(self):
        primary = self.sign_in(self.root / "primary", PERSONAL_LOGIN)
        backup = self.sign_in(self.root / "backup")
        spare = self.sign_in(self.root / "spare")
        self.write_docket_config(primary, backup, spare)
        self.record_limit(backup, -timedelta(days=2), -timedelta(days=1))
        self.record_limit(
            primary, -timedelta(hours=3), -timedelta(hours=2), login=TEAM_LOGIN
        )
        self.record_limit(
            self.root / "unlisted",
            -timedelta(hours=1),
            -timedelta(minutes=30),
            login=TEAM_LOGIN,
        )

        report = self.output(self.invoke("accounts", cwd=self.root))

        self.assertEqual(report["order"], [str(spare), str(primary), str(backup), ""])

    def test_usage_limit_skips_later_dirs_signed_in_to_the_same_login(self):
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        backup = self.sign_in(self.root / "backup", TEAM_LOGIN)
        spare = self.sign_in(self.root / "spare", PERSONAL_LOGIN)
        self.write_docket_config(primary, backup, spare)
        self.limit_config_dirs(primary, backup)

        self.assert_success(self.run_review("claude", mode="usage_limit"))

        self.assertEqual(self.child_config_dirs(), [str(primary), str(spare)])

    def test_usage_limit_skips_the_session_account_signed_in_to_the_same_login(self):
        self.sign_in(None, TEAM_LOGIN)
        primary = self.sign_in(self.root / "primary", TEAM_LOGIN)
        self.write_docket_config(primary)
        self.limit_config_dirs(primary, "")

        result = self.run_review("claude", mode="usage_limit")

        self.assert_usage_limit_failure(result, calls=1)

    def test_recorded_limits_and_the_fallback_agree_on_which_dirs_share_a_login(self):
        limits = self.home / ".docket/limits.jsonl"
        for name, login in (
            ("the same login", TEAM_LOGIN),
            ("the same account in another organization", TEAM_USER_IN_ANOTHER_ORG),
            ("another account in the same organization", TEAM_COLLEAGUE),
            ("only the same account", (TEAM_LOGIN[0], None)),
            ("no login", None),
        ):
            with self.subTest(name):
                primary = self.sign_in(self.root / name / "primary", TEAM_LOGIN)
                backup = self.sign_in(self.root / name / "backup", login)
                self.write_docket_config(primary, backup)
                self.record_limit(
                    primary, -timedelta(hours=1), timedelta(days=1), login=TEAM_LOGIN
                )
                report = self.output(self.invoke("accounts", cwd=self.root))
                limits.unlink()
                self.limit_config_dirs(primary, backup)
                launched = len(self.calls())
                # A new HEAD keeps the previous subtest's review from being reused.
                self.git("commit", "--allow-empty", "-qm", name)

                self.run_review("claude", mode="usage_limit")

                same_login = login == TEAM_LOGIN
                self.assertEqual(str(backup) in report["limits"], same_login)
                self.assertEqual(
                    str(backup) in self.child_config_dirs()[launched:], not same_login
                )

    def test_limit_text_in_review_summary_is_a_normal_success(self):
        self.use_team_config()

        self.assert_success(self.run_review("claude", mode="limit_prose"))

        self.assertEqual(len(self.calls()), 1)

    def run_since(self, run_id, harness="codex", pr_url=PR_URL, **kwargs):
        return self.run_review(harness, "--since-run", run_id, pr_url=pr_url, **kwargs)

    def review_since_earlier_run(self, pr_url=PR_URL, **kwargs):
        earlier = self.assert_success(self.run_review(pr_url=pr_url))
        self.git("commit", "-qm", "Follow-up fix", "--allow-empty")
        return earlier, self.run_since(earlier["run_id"], pr_url=pr_url, **kwargs)

    def skill_arguments(self, call):
        return call["prompt"].splitlines()[1]

    def assert_since_run_refused(self, run_id, pr_url=PR_URL):
        before = self.state_path.read_bytes() if self.state_path.exists() else None
        launched = len(self.calls())
        result = self.run_since(run_id, pr_url=pr_url)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertTrue(result.stderr.strip())
        self.assertEqual(len(self.calls()), launched)
        after = self.state_path.read_bytes() if self.state_path.exists() else None
        self.assertEqual(after, before)

    def test_since_run_appends_to_the_earlier_review_and_archives_both(self):
        earlier, result = self.review_since_earlier_run(mode="append_seed")
        state = self.assert_success(result)
        expected = (
            Path(earlier["review_file"]).read_text()
            + "\n## Second review\n\nAppended by the fixture.\n"
        )
        self.assertEqual(Path(state["review_file"]).read_text(), expected)
        self.assertEqual(state["archive_review_file"], str(self.archive_file))
        self.assertEqual(self.archive_file.read_text(), expected)

    def test_since_run_child_returning_the_untouched_seed_fails(self):
        earlier, result = self.review_since_earlier_run(mode="untouched_seed")
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertEqual(self.state()["phase"], "failed")
        self.assertIn("predates", self.state()["error"])
        self.assertEqual(
            self.archive_file.read_bytes(), Path(earlier["review_file"]).read_bytes()
        )

    def test_since_run_requests_an_append_and_both_modes_forbid_resolving_threads(self):
        earlier, result = self.review_since_earlier_run()
        self.assert_success(result)
        plain, follow_up = self.calls()
        self.assertEqual(
            self.skill_arguments(plain), f"{PR_URL} --fix --force --overwrite --full"
        )
        self.assertEqual(
            self.skill_arguments(follow_up), f"{PR_URL} --fix --force --append"
        )
        for call in (plain, follow_up):
            self.assertRegex(call["prompt"], r"Do not [^.]*resolve review threads")

    def test_reuse_requires_the_same_since_run(self):
        first = self.assert_success(self.run_review())
        self.git("commit", "-qm", "Second head", "--allow-empty")
        second = self.assert_success(self.run_review())
        since_first = self.assert_success(self.run_since(first["run_id"]))
        repeated = self.assert_success(self.run_since(first["run_id"]))
        since_second = self.assert_success(self.run_since(second["run_id"]))
        plain = self.assert_success(self.run_review())
        self.assertIsNone(first.get("since_run_id"))
        self.assertEqual(since_first["since_run_id"], first["run_id"])
        self.assertEqual(repeated["run_id"], since_first["run_id"])
        self.assertEqual(
            len(
                {
                    second["run_id"],
                    since_first["run_id"],
                    since_second["run_id"],
                    plain["run_id"],
                }
            ),
            4,
        )
        self.assertEqual(len(self.calls()), 5)

    def test_since_run_checks_the_earlier_run_before_reusing_a_result(self):
        earlier, result = self.review_since_earlier_run()
        self.assert_success(result)
        review = Path(earlier["review_file"])
        review.write_bytes(review.read_bytes() + b"Edited after the review finished.\n")
        self.assert_since_run_refused(earlier["run_id"])

    def test_since_run_refuses_ids_that_do_not_name_a_recorded_run(self):
        self.assert_since_run_refused(str(uuid.uuid4()))
        earlier = self.assert_success(self.run_review())
        for run_id in (
            str(uuid.uuid4()),
            "not-a-uuid",
            earlier["run_id"].upper(),
            f"../go-reviews/{earlier['run_id']}",
        ):
            with self.subTest(run_id=run_id):
                self.assert_since_run_refused(run_id)

    def test_since_run_refuses_a_run_recorded_for_another_review(self):
        earlier = self.assert_success(self.run_review())
        record = self.repo / ".notes/go-reviews" / earlier["run_id"] / "state.json"
        recorded = json.loads(record.read_text())
        outside = self.swap_root / "same-review.md"
        outside.write_bytes(Path(earlier["review_file"]).read_bytes())
        for field, value in (
            ("phase", "failed"),
            ("pr_url", PR_URL.replace("123", "124")),
            ("branch", "another-feature"),
            ("worktree", str(self.root / "another checkout")),
            ("review_file", str(outside)),
        ):
            with self.subTest(field=field):
                record.write_text(json.dumps(dict(recorded, **{field: value})))
                self.assert_since_run_refused(earlier["run_id"])

    def test_archive_and_seed_paths_lowercase_org_and_repo(self):
        earlier, result = self.review_since_earlier_run(
            pr_url=PR_URL.replace("org/repo", "Org/Repo")
        )
        self.assert_success(result)
        self.assertEqual(earlier["archive_review_file"], str(self.archive_file))
        self.assertEqual(os.listdir(self.review_root), ["org"])
        self.assertEqual(os.listdir(self.review_root / "org"), ["repo"])
        review_dir = Path(self.calls()[-1]["environment"]["REVIEW_CODE_REVIEW_DIR"])
        self.assertIn("org", os.listdir(review_dir))
        self.assertEqual(os.listdir(review_dir / "org"), ["repo"])
        self.assertEqual(os.listdir(review_dir / "org/repo"), ["pr-123.md"])

    def test_since_run_seeds_the_usage_limit_fallback_attempt(self):
        earlier = self.assert_success(self.run_review())
        self.git("commit", "-qm", "Follow-up fix", "--allow-empty")
        self.limit_config_dirs(self.use_team_config())

        state = self.assert_success(
            self.run_since(earlier["run_id"], "claude", mode="usage_limit")
        )

        self.assertIn("fallback_from_run_id", state)
        self.assertEqual(state["since_run_id"], earlier["run_id"])
        limited, fallback = self.calls()[1:]
        for call in (limited, fallback):
            seed = Path(call["environment"]["REVIEW_CODE_REVIEW_DIR"])
            self.assertEqual(
                (seed / "org/repo/pr-123.md").read_bytes(),
                Path(earlier["review_file"]).read_bytes(),
            )
            self.assertEqual(
                self.skill_arguments(call), f"{PR_URL} --fix --force --append"
            )


if __name__ == "__main__":
    unittest.main()
