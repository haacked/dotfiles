#!/usr/bin/env python3
"""Run a review in a fresh process and retain its result for the parent workflow."""

import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


SCHEMA = {
    "type": "object",
    "properties": {
        "status": {"type": "string", "enum": ["completed", "blocked"]},
        "review_file": {"type": "string"},
        "summary": {"type": "string"},
    },
    "required": ["status", "review_file", "summary"],
    "additionalProperties": False,
}
PATHSPEC = ["--", ".", ":(exclude).notes"]


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], stderr=subprocess.PIPE
    )


def snapshot(root):
    status = git(
        root, "status", "--porcelain=v1", "-z", "--untracked-files=all", *PATHSPEC
    )
    digest = hashlib.sha256(status)
    for args in [("diff", "--binary", "HEAD"), ("diff", "--binary", "--cached")]:
        digest.update(git(root, *args, *PATHSPEC))
    for name in git(
        root, "ls-files", "--others", "--exclude-standard", "-z", *PATHSPEC
    ).split(b"\0"):
        if name:
            path = root / os.fsdecode(name)
            digest.update(name + b"\0")
            digest.update(
                os.fsencode(os.readlink(path))
                if path.is_symlink()
                else path.read_bytes()
            )
    return {
        "branch": git(root, "branch", "--show-current").decode().strip(),
        "input_sha": git(root, "rev-parse", "HEAD").decode().strip(),
        "fingerprint": digest.hexdigest(),
        "dirty": bool(status),
    }


def save(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, indent=2) + "\n")
    temporary.replace(path)


def read_state(path):
    if not path.exists():
        return {"phase": "pending"}
    value = json.loads(path.read_text())
    if not isinstance(value, dict):
        raise ValueError("Review state must be a JSON object")
    return value


def process_exists(pid):
    if not isinstance(pid, int) or pid <= 0:
        return False
    try:
        os.kill(pid, 0)
        return True
    except ProcessLookupError:
        return False
    except PermissionError:
        return True


def locked(path):
    if not path.exists():
        return False
    with path.open("r") as handle:
        try:
            fcntl.flock(handle, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            return True
        return False


def status(root, state_path, lock_path):
    state = read_state(state_path)
    if state["phase"] == "running":
        if not locked(lock_path) and not process_exists(state.get("child_pid")):
            state["phase"] = "interrupted"
    elif state["phase"] == "reviewed":
        current = snapshot(root)
        review_file = Path(state.get("review_file", ""))
        state["artifact_valid"] = review_file.is_file() and hashlib.sha256(
            review_file.read_bytes()
        ).hexdigest() == state.get("review_sha256")
        state["current_branch"] = current["branch"]
        state["current_sha"] = current["input_sha"]
        state["current_fingerprint"] = current["fingerprint"]
        state["stale"] = (
            state.get("worktree") != str(root)
            or state.get("branch") != current["branch"]
            or state.get("input_sha") != current["input_sha"]
            or state.get("output_fingerprint") != current["fingerprint"]
            or not state["artifact_valid"]
        )
    return state


def command(harness, root, attempt):
    if harness == "claude":
        return [
            "claude",
            "-p",
            "--output-format",
            "json",
            "--json-schema",
            json.dumps(SCHEMA),
            "--no-session-persistence",
            "--permission-prompts",
            "none",
        ]
    schema = attempt / "schema.json"
    save(schema, SCHEMA)
    args = [
        "codex",
        "exec",
        "--json",
        "--ephemeral",
        "--sandbox",
        "workspace-write",
        "--approve-for-me",
        "-C",
        str(root),
        "--output-schema",
        str(schema),
        "--output-last-message",
        str(attempt / "result.json"),
    ]
    skill_dir = Path.home() / ".agents" / "skills" / "review-code"
    if skill_dir.is_dir():
        for directory in [".sessions", ".reviews", ".worktrees"]:
            cache = skill_dir / directory
            cache.mkdir(exist_ok=True)
            args.extend(["--add-dir", str(cache)])
    return args + ["-"]


def completion(harness, attempt):
    if harness == "claude":
        output = json.loads((attempt / "stdout.jsonl").read_text())
        if (
            not isinstance(output, dict)
            or output.get("type") != "result"
            or output.get("subtype") != "success"
            or output.get("is_error") is not False
        ):
            raise ValueError("Claude did not report a successful review turn")
        result = output.get("structured_output")
    else:
        completed = False
        for line in (attempt / "stdout.jsonl").read_text().splitlines():
            event = json.loads(line)
            if not isinstance(event, dict):
                raise ValueError("Codex emitted an invalid event")
            if event.get("type") in {"error", "turn.failed"}:
                raise ValueError("Codex reported an unsuccessful review turn")
            if event.get("type") == "turn.completed":
                completed = True
        if not completed:
            raise ValueError("Codex did not report a completed review turn")
        result = json.loads((attempt / "result.json").read_text())
    if not isinstance(result, dict) or not all(
        isinstance(result.get(k), str) for k in SCHEMA["required"]
    ):
        raise ValueError("The review completion record is missing or malformed")
    if result["status"] != "completed":
        raise ValueError("Review blocked: " + result["summary"])
    return result


def stop_process(process):
    if process is None:
        return
    try:
        os.killpg(process.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        process.wait(timeout=3)
    except subprocess.TimeoutExpired:
        pass
    # The CLI can exit before its review agents do.
    # Stop the remaining process group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(args, root, notes, state_path, lock_path):
    notes.mkdir(exist_ok=True)
    with lock_path.open("a+") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("A review is already running in this worktree")
        previous = read_state(state_path)
        if previous["phase"] == "running" and process_exists(previous.get("child_pid")):
            raise ValueError("The previous review process is still running")
        if previous["phase"] == "reviewed":
            cached = status(root, state_path, lock_path)
            if (
                not cached["stale"]
                and cached.get("harness") == args.harness
                and cached.get("pr_url") == args.pr_url
            ):
                return cached
        before = snapshot(root)
        if before["dirty"]:
            raise ValueError(
                "Review requires a clean checkout; inspect and commit any partial fixes before retrying"
            )
        if not before["branch"]:
            raise ValueError("Review requires a branch, not a detached HEAD")
        run_id = str(uuid.uuid4())
        attempt = notes / "go-reviews" / run_id
        attempt.mkdir(parents=True)
        state = {
            "phase": "running",
            "run_id": run_id,
            "harness": args.harness,
            "pr_url": args.pr_url,
            "worktree": str(root),
            "branch": before["branch"],
            "input_sha": before["input_sha"],
            "input_fingerprint": before["fingerprint"],
            "next_action": "wait-for-review",
            "started_at": time.time(),
            "log_file": str(attempt / "stdout.jsonl"),
            "error_log": str(attempt / "stderr.log"),
        }
        save(state_path, state)
        save(attempt / "state.json", state)
        process = None
        try:
            if not shutil.which(args.harness):
                raise ValueError(
                    f"{args.harness} CLI is not installed or is not on PATH"
                )
            invocation = "/review-code" if args.harness == "claude" else "$review-code"
            prompt = f"""Invoke the installed {invocation} skill with exactly these arguments:
{args.pr_url} --fix --force --overwrite --full

The instructions below describe the caller's workflow; do not include them in the skill arguments. Run the skill in this checkout. This is the review stage of an authorized go workflow, in a fresh conversation. Run its full reviewer fleet and apply its clean local fixes. The caller owns validation, committing, pushing, and all later stages. Do not commit, push, publish a GitHub review, run go, or change branches. Do not load go-state or implementation conversation transcripts. Keep repository instructions and normal permission checks in force.

Return the structured result only after the skill has finished and saved its review document. Set status to completed, review_file to the absolute path of that saved document, and summary to a concise outcome. If the skill cannot finish, is unavailable, needs input, or is denied permission, return status blocked and explain why in summary. A partial review must not be reported as completed.
"""
            (attempt / "request.txt").write_text(prompt)
            environment = os.environ.copy()
            for name in ["CLAUDECODE", "CLAUDE_CODE_SESSION_ID", "CODEX_THREAD_ID"]:
                environment.pop(name, None)
            argv = command(args.harness, root, attempt)
            with (
                (attempt / "stdout.jsonl").open("w") as stdout,
                (attempt / "stderr.log").open("w") as stderr,
            ):
                process = subprocess.Popen(
                    argv,
                    cwd=root,
                    env=environment,
                    stdin=subprocess.PIPE,
                    stdout=stdout,
                    stderr=stderr,
                    text=True,
                    start_new_session=True,
                    pass_fds=(lock.fileno(),),
                )
                state["child_pid"] = process.pid
                save(state_path, state)
                process.communicate(prompt, timeout=args.timeout)
            if process.returncode:
                raise ValueError(
                    f"{args.harness} exited with status {process.returncode}"
                )
            result = completion(args.harness, attempt)
            source = Path(result["review_file"])
            if not source.is_absolute() or not source.is_file():
                raise ValueError(
                    "The review artifact is missing or is not an absolute file path"
                )
            if source.stat().st_size == 0:
                raise ValueError("The review artifact is empty")
            if source.stat().st_mtime < state["started_at"]:
                raise ValueError("The review artifact predates this attempt")
            after = snapshot(root)
            if (
                after["branch"] != before["branch"]
                or after["input_sha"] != before["input_sha"]
            ):
                raise ValueError(
                    "The review changed the branch or HEAD; inspect its changes before continuing"
                )
            saved_review = attempt / "review.md"
            if source.resolve() != saved_review:
                shutil.copyfile(source, saved_review)
            state.update(
                phase="reviewed",
                next_action="validate-review-fixes",
                review_file=str(saved_review),
                source_review_file=str(source),
                review_sha256=hashlib.sha256(saved_review.read_bytes()).hexdigest(),
                output_fingerprint=after["fingerprint"],
                summary=result["summary"],
            )
        except (
            OSError,
            ValueError,
            subprocess.SubprocessError,
            KeyboardInterrupt,
        ) as error:
            stop_process(process)
            state.update(
                phase="failed",
                next_action="inspect-review-failure",
                error=str(error) or "Review interrupted",
            )
        finally:
            state["finished_at"] = time.time()
            save(attempt / "state.json", state)
            save(state_path, state)
        return state


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="action", required=True)
    runner = commands.add_parser("run")
    runner.add_argument("--harness", choices=["claude", "codex"], required=True)
    runner.add_argument("--pr-url", required=True)
    runner.add_argument("--timeout", type=float, default=1800)
    commands.add_parser("status")
    args = parser.parse_args()
    if args.action == "run":
        if not re.fullmatch(
            r"https://[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*",
            args.pr_url,
        ):
            parser.error("--pr-url must be an HTTPS pull request URL")
        if not 0 < args.timeout < float("inf"):
            parser.error("--timeout must be a finite positive number of seconds")
    try:
        root = Path(
            git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip()
        ).resolve()
        notes = root / ".notes"
        state_path = notes / "go-review-state.json"
        lock_path = notes / "go-review.lock"
        if args.action == "status":
            result = status(root, state_path, lock_path)
        else:
            signal.signal(signal.SIGTERM, interrupt)
            result = run(args, root, notes, state_path, lock_path)
        print(json.dumps(result))
        return 1 if args.action == "run" and result["phase"] != "reviewed" else 0
    except (OSError, ValueError, subprocess.SubprocessError) as error:
        print(f"review runner: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
