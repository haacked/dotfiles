#!/usr/bin/env python3
"""Run a review in a fresh process and retain its result for the parent workflow."""

import argparse
from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import subprocess
import sys
import stat
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
CLAUDE_CONFIG_SETTING = "GO_REVIEW_CLAUDE_CONFIG_DIR"
# Claude Code 2.1.302 treats an error message that starts with one of these as a usage limit.
USAGE_LIMIT_PREFIXES = (
    "You've hit your",
    "You've reached your",
    "You're out of usage credits",
    "You're out of extra usage",
    "Your org is out of usage",
    "Your seat type doesn't include",
    "Your usage allocation has been disabled",
    "Your group's usage limit",
    "Fable 5 requires usage credits",
)


class UsageLimitReached(ValueError):
    pass


def git(root, *args):
    return subprocess.check_output(
        ["git", "-C", str(root), *args], stderr=subprocess.PIPE
    )


def current_branch(root):
    return git(root, "branch", "--show-current").decode().strip()


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
        "branch": current_branch(root),
        "input_sha": git(root, "rev-parse", "HEAD").decode().strip(),
        "fingerprint": digest.hexdigest(),
        "dirty": bool(status),
    }


def save(path, value):
    directory = os.open(path.parent, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        save_in_directory(directory, path.name, value)
    finally:
        os.close(directory)


def save_in_directory(directory, name, value):
    while True:
        temporary = f".{name}.{uuid.uuid4().hex}.tmp"
        try:
            descriptor = os.open(
                temporary,
                os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                0o600,
                dir_fd=directory,
            )
            break
        except FileExistsError:
            continue
    try:
        with os.fdopen(descriptor, "w") as handle:
            handle.write(json.dumps(value, indent=2) + "\n")
        os.replace(
            temporary,
            name,
            src_dir_fd=directory,
            dst_dir_fd=directory,
        )
    except BaseException:
        try:
            os.unlink(temporary, dir_fd=directory)
        except FileNotFoundError:
            pass
        raise


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


def cached_review_valid(state, state_path):
    run_id = state.get("run_id")
    if not isinstance(run_id, str):
        return False
    try:
        if str(uuid.UUID(run_id)) != run_id:
            return False
    except ValueError:
        return False
    expected = state_path.parent / "go-reviews" / run_id / "review.md"
    if state.get("review_file") != str(expected):
        return False
    try:
        with ExitStack() as resources:
            notes = open_directory(state_path.parent)
            resources.callback(os.close, notes)
            attempts = os.open(
                "go-reviews",
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=notes,
            )
            resources.callback(os.close, attempts)
            attempt = os.open(
                run_id,
                os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                dir_fd=attempts,
            )
            resources.callback(os.close, attempt)
            descriptor = os.open(
                "review.md", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=attempt
            )
            report = resources.enter_context(os.fdopen(descriptor, "rb"))
            if not stat.S_ISREG(os.fstat(report.fileno()).st_mode):
                return False
            digest = hashlib.sha256()
            for chunk in iter(lambda: report.read(1024 * 1024), b""):
                digest.update(chunk)
            return digest.hexdigest() == state.get("review_sha256")
    except OSError:
        return False


def status(root, state_path, lock_path):
    state = read_state(state_path)
    if state["phase"] == "running":
        if not locked(lock_path) and not process_exists(state.get("child_pid")):
            state["phase"] = "interrupted"
    elif state["phase"] == "failed" and state.get("usage_limit") and locked(lock_path):
        # run() saves the limited attempt before it starts the fallback attempt.
        state["phase"] = "running"
    elif state["phase"] == "reviewed":
        current = snapshot(root)
        state["artifact_valid"] = cached_review_valid(state, state_path)
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
        "--approve-for-me",
        "-C",
        str(root),
        "--output-schema",
        str(schema),
        "--output-last-message",
        str(attempt / "result.json"),
    ]
    return args + ["-"]


def claude_config_dirs(harness):
    """Lists the config dirs to review under, in order. None keeps the parent's account."""
    setting = os.environ.get(CLAUDE_CONFIG_SETTING) if harness == "claude" else None
    if not setting:
        return [None]
    configured = Path(setting).expanduser()
    parent = os.environ.get("CLAUDE_CONFIG_DIR")
    if parent and Path(parent).expanduser().resolve() == configured.resolve():
        return [configured]
    return [configured, None]


def check_claude_account(config_dir):
    if not config_dir.is_absolute():
        raise ValueError(
            f"{CLAUDE_CONFIG_SETTING} must be an absolute path, not {config_dir}"
        )
    try:
        config = json.loads((config_dir / ".claude.json").read_text())
    except (OSError, ValueError):
        config = None
    if not isinstance(config, dict) or not config.get("oauthAccount"):
        raise ValueError(
            f"{CLAUDE_CONFIG_SETTING} names {config_dir}, which is not signed in. "
            f"Sign in with `CLAUDE_CONFIG_DIR={shlex.quote(str(config_dir))} claude` "
            f"and /login, or unset {CLAUDE_CONFIG_SETTING} to review on the current account"
        )
    skills = config_dir / "skills"
    if not (skills / "review-code").exists():
        raise ValueError(
            f"{CLAUDE_CONFIG_SETTING} names {config_dir}, which has no review-code skill. "
            f"Link review-code into {skills}"
        )


def review_environment(harness, attempt, claude_config_dir):
    environment = os.environ.copy()
    for name in [
        "CLAUDECODE",
        "CLAUDE_CODE_SESSION_ID",
        "CODEX_THREAD_ID",
        "DEBUG_SESSION_DIR",
    ]:
        environment.pop(name, None)
    if harness == "codex":
        environment.pop("CLAUDE_CONFIG_DIR", None)
    elif claude_config_dir:
        environment["CLAUDE_CONFIG_DIR"] = str(claude_config_dir)
    directories = {
        "CLAUDE_SESSION_DIR": attempt / "sessions",
        "REVIEW_CODE_REVIEW_DIR": attempt / "reviews",
        "REVIEW_CODE_WORKTREE_DIR": attempt / "worktrees",
        "REVIEW_CODE_ARTIFACTS_DIR": attempt / "artifacts",
        "REVIEW_CODE_DEBUG_PATH": attempt / "debug",
        "REVIEW_CODE_MARKER_DIR": attempt / "sessions",
    }
    for name, directory in directories.items():
        directory.mkdir(exist_ok=True)
        environment[name] = str(directory)
    environment["REVIEW_CODE_HOOK_LOG"] = str(
        attempt / "sessions" / "session-clear-hook.log"
    )
    return environment


def check_review_support(harness, environment, review_root):
    shared_skill = Path.home() / ".agents" / "skills" / "review-code"
    claude_skill = (
        Path(environment.get("CLAUDE_CONFIG_DIR") or Path.home() / ".claude")
        / "skills"
        / "review-code"
    )
    skill_dir = (
        claude_skill
        if harness == "claude" and (claude_skill.exists() or claude_skill.is_symlink())
        else shared_skill
    )
    helper = skill_dir / "scripts" / "helpers" / "config-helpers.sh"
    message = (
        "Update the installed review-code skill to support "
        "REVIEW_CODE_REVIEW_DIR before running go reviews"
    )
    if not helper.is_file():
        raise ValueError(message)
    result = subprocess.run(
        ["bash", "-c", 'source "$1"; get_review_root', "go-review", str(helper)],
        env=environment,
        capture_output=True,
        text=True,
        timeout=10,
    )
    if result.returncode or Path(result.stdout.strip()) != review_root:
        raise ValueError(message)
    return skill_dir


def claude_result(attempt):
    try:
        output = json.loads((attempt / "stdout.jsonl").read_text())
    except (OSError, ValueError):
        return None
    if isinstance(output, dict) and output.get("type") == "result":
        return output
    return None


def check_usage_limit(attempt, claude_config_dir):
    output = claude_result(attempt)
    # Review prose can mention limits. Only an error result counts as a limit.
    if output is None or output.get("is_error") is not True:
        return
    errors = output.get("errors")
    for message in [
        output.get("result"),
        *(errors if isinstance(errors, list) else []),
    ]:
        if isinstance(message, str) and message.startswith(USAGE_LIMIT_PREFIXES):
            account = claude_config_dir or "the default Claude config"
            raise UsageLimitReached(
                f"Claude hit its usage limit under {account}: {message}"
            )


def completion(harness, attempt):
    if harness == "claude":
        output = claude_result(attempt)
        if (
            output is None
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


def open_directory(path):
    return os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)


def open_lock(directory_path, name):
    directory = open_directory(directory_path)
    try:
        descriptor = os.open(
            name,
            os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW,
            0o600,
            dir_fd=directory,
        )
    finally:
        os.close(directory)
    return os.fdopen(descriptor, "a+")


def verify_directory(path, descriptor, label):
    expected = os.fstat(descriptor)
    try:
        current = path.stat(follow_symlinks=False)
    except OSError as error:
        raise ValueError(f"The review changed the {label} directory") from error
    if not stat.S_ISDIR(current.st_mode) or (
        current.st_dev,
        current.st_ino,
    ) != (expected.st_dev, expected.st_ino):
        raise ValueError(f"The review changed the {label} directory")


def validate_review_artifact(path, started_at, review_root, review_root_descriptor):
    verify_directory(review_root, review_root_descriptor, "review-code review root")
    if not path.is_absolute() or path.is_symlink():
        raise ValueError(
            "The review artifact is missing or is not an absolute regular file"
        )
    try:
        source = path.resolve(strict=True)
    except OSError as error:
        raise ValueError("The review artifact is missing") from error
    if not source.is_relative_to(review_root):
        raise ValueError("The review artifact is outside the review-code review root")
    if not source.is_file():
        raise ValueError("The review artifact is not a regular file")
    metadata = source.stat()
    if metadata.st_size == 0:
        raise ValueError("The review artifact is empty")
    if metadata.st_mtime < started_at:
        raise ValueError("The review artifact predates this attempt")
    return source


def copy_review(source, directory, name):
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL
    if hasattr(os, "O_NOFOLLOW"):
        flags |= os.O_NOFOLLOW
    descriptor = os.open(name, flags, 0o600, dir_fd=directory)
    digest = hashlib.sha256()
    try:
        with (
            source.open("rb") as input_file,
            os.fdopen(descriptor, "wb") as output_file,
        ):
            descriptor = -1
            while chunk := input_file.read(1024 * 1024):
                digest.update(chunk)
                output_file.write(chunk)
    except BaseException:
        if descriptor >= 0:
            os.close(descriptor)
        try:
            os.unlink(name, dir_fd=directory)
        except FileNotFoundError:
            pass
        raise
    return digest.hexdigest()


def pr_review_path(pr_url):
    org, repo, _, number = pr_url.split("/")[-4:]
    # review-code lowercases the organization and repository in its own review paths.
    return org.lower(), repo.lower(), f"pr-{number}.md"


def open_pr_directory(root, org, repo, resources):
    directory = open_directory(root)
    resources.callback(os.close, directory)
    for component in [org, repo]:
        try:
            os.mkdir(component, 0o700, dir_fd=directory)
        except FileExistsError:
            pass
        directory = os.open(
            component,
            os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
            dir_fd=directory,
        )
        resources.callback(os.close, directory)
    return directory


def earlier_review(root, state_path, run_id, pr_url):
    try:
        # The run_id check below refuses spellings other than the canonical one.
        state = read_state(
            state_path.parent / "go-reviews" / str(uuid.UUID(run_id)) / "state.json"
        )
    except ValueError:
        state = {}
    if not (
        state.get("phase") == "reviewed"
        and state.get("run_id") == run_id
        and state.get("pr_url") == pr_url
        and state.get("branch") == current_branch(root)
        and state.get("worktree") == str(root)
        and cached_review_valid(state, state_path)
    ):
        raise ValueError(
            f"--since-run {run_id} does not name a finished review of this pull request on this branch"
        )
    return Path(state["review_file"])


def seed_review(source, review_root, pr_url):
    org, repo, filename = pr_review_path(pr_url)
    with ExitStack() as resources:
        directory = open_pr_directory(review_root, org, repo, resources)
        copy_review(source, directory, filename)
        # The seed keeps the earlier review's mtime.
        # A child that returns the seed unchanged fails the check that rejects artifacts older than the attempt.
        modified = source.stat()
        os.utime(
            filename,
            ns=(modified.st_atime_ns, modified.st_mtime_ns),
            dir_fd=directory,
            follow_symlinks=False,
        )


def archive_review(source, pr_url, skill_dir):
    org, repo, filename = pr_review_path(pr_url)
    archive_root = skill_dir / ".reviews"
    archive_root.mkdir(exist_ok=True)
    with ExitStack() as resources:
        directory = open_pr_directory(archive_root, org, repo, resources)
        temporary = f".{filename}.{uuid.uuid4().hex}.tmp"
        try:
            copy_review(source, directory, temporary)
            os.replace(temporary, filename, src_dir_fd=directory, dst_dir_fd=directory)
        finally:
            try:
                os.unlink(temporary, dir_fd=directory)
            except FileNotFoundError:
                pass
    return archive_root / org / repo / filename


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
    # The CLI can exit while review agents remain in its process group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def run(args, root, notes, state_path, lock_path):
    notes.mkdir(exist_ok=True)
    with open_lock(notes, lock_path.name) as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ValueError("A review is already running in this worktree")
        previous = read_state(state_path)
        if previous["phase"] == "running" and process_exists(previous.get("child_pid")):
            raise ValueError("The previous review process is still running")
        seed = (
            earlier_review(root, state_path, args.since_run, args.pr_url)
            if args.since_run
            else None
        )
        if previous["phase"] == "reviewed":
            cached = status(root, state_path, lock_path)
            if (
                not cached["stale"]
                and cached.get("harness") == args.harness
                and cached.get("pr_url") == args.pr_url
                and cached.get("since_run_id") == args.since_run
            ):
                return cached
        before = snapshot(root)
        if before["dirty"]:
            raise ValueError(
                "Review requires a clean checkout; inspect and commit any partial fixes before retrying"
            )
        if not before["branch"]:
            raise ValueError("Review requires a branch, not a detached HEAD")
        fallback_from = None
        for claude_config_dir in claude_config_dirs(args.harness):
            state = review_attempt(
                args,
                root,
                notes,
                state_path,
                lock,
                before,
                seed,
                claude_config_dir,
                fallback_from,
            )
            # A second child must not review on top of the first child's partial fixes.
            if not state.get("usage_limit") or snapshot(root) != before:
                break
            fallback_from = state["run_id"]
        return state


def review_attempt(
    args, root, notes, state_path, lock, before, seed, claude_config_dir, fallback_from
):
    run_id = str(uuid.uuid4())
    attempt = notes / "go-reviews" / run_id
    attempt.mkdir(parents=True)
    notes_descriptor = open_directory(notes)
    attempts_descriptor = open_directory(attempt.parent)
    attempt_descriptor = open_directory(attempt)
    state = {
        "phase": "running",
        "run_id": run_id,
        "harness": args.harness,
        "pr_url": args.pr_url,
        "since_run_id": args.since_run,
        "worktree": str(root),
        "branch": before["branch"],
        "input_sha": before["input_sha"],
        "input_fingerprint": before["fingerprint"],
        "next_action": "wait-for-review",
        "started_at": time.time(),
        "log_file": str(attempt / "stdout.jsonl"),
        "error_log": str(attempt / "stderr.log"),
    }
    if fallback_from:
        state["fallback_from_run_id"] = fallback_from
    process = None
    review_root = attempt / "reviews"
    review_root_descriptor = None
    try:
        save_in_directory(notes_descriptor, state_path.name, state)
        save_in_directory(attempt_descriptor, "state.json", state)
        if not shutil.which(args.harness):
            raise ValueError(f"{args.harness} CLI is not installed or is not on PATH")
        invocation = "/review-code" if args.harness == "claude" else "$review-code"
        # `claude -p --json-schema` takes the first end of turn as the final result.
        # A turn that ends to wait for a background subagent returns before the review exists.
        # Codex dispatch blocks in a shell, so it needs no such rule.
        wait_rule = (
            "\nThis run is non-interactive. Your first end of turn ends the run and sends your structured result. Never end a turn while a subagent is still running. Start every subagent with run_in_background set to false, so each call returns its result before you continue. This rule overrides any skill instruction to wait for background completion notifications. To run independent subagents at the same time, start them in one message.\n"
            if args.harness == "claude"
            else ""
        )
        skill_arguments = (
            "--fix --force --append" if seed else "--fix --force --overwrite --full"
        )
        prompt = f"""Invoke the installed {invocation} skill with exactly these arguments:
{args.pr_url} {skill_arguments}

The instructions below describe the caller's workflow; do not include them in the skill arguments. Run the skill in this checkout. This is the review stage of an authorized go workflow, in a fresh conversation. Run its full reviewer fleet and apply its clean local fixes. The caller owns validation, committing, pushing, and all later stages. Do not commit, push, publish a GitHub review, resolve review threads, run go, or change branches. Do not load go-state or implementation conversation transcripts. Keep repository instructions and normal permission checks in force.

Return the structured result only after the skill has finished and saved its review document. Set status to completed, review_file to the absolute path of that saved document, and summary to a concise outcome. If the skill cannot finish, is unavailable, needs input, or is denied permission, return status blocked and explain why in summary. A partial review must not be reported as completed.
{wait_rule}"""
        (attempt / "request.txt").write_text(prompt)
        environment = review_environment(args.harness, attempt, claude_config_dir)
        if args.harness == "claude":
            state["claude_config_dir"] = environment.get("CLAUDE_CONFIG_DIR")
        if claude_config_dir:
            check_claude_account(claude_config_dir)
        skill_dir = check_review_support(args.harness, environment, review_root)
        if seed:
            seed_review(seed, review_root, args.pr_url)
        argv = command(args.harness, root, attempt)
        review_root_descriptor = open_directory(review_root)
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
            save_in_directory(notes_descriptor, state_path.name, state)
            process.communicate(prompt, timeout=args.timeout)
        stop_process(process)
        verify_directory(notes, notes_descriptor, "notes")
        verify_directory(attempt.parent, attempts_descriptor, "review attempts")
        verify_directory(attempt, attempt_descriptor, "review attempt")
        if args.harness == "claude":
            check_usage_limit(attempt, state["claude_config_dir"])
        if process.returncode:
            raise ValueError(f"{args.harness} exited with status {process.returncode}")
        result = completion(args.harness, attempt)
        source = validate_review_artifact(
            Path(result["review_file"]),
            state["started_at"],
            review_root,
            review_root_descriptor,
        )
        after = snapshot(root)
        if (
            after["branch"] != before["branch"]
            or after["input_sha"] != before["input_sha"]
        ):
            raise ValueError(
                "The review changed the branch or HEAD; inspect its changes before continuing"
            )
        saved_review = attempt / "review.md"
        review_sha256 = copy_review(source, attempt_descriptor, saved_review.name)
        archived_review = archive_review(saved_review, args.pr_url, skill_dir)
        state.update(
            phase="reviewed",
            next_action="validate-review-fixes",
            review_file=str(saved_review),
            archive_review_file=str(archived_review),
            source_review_file=str(source),
            review_sha256=review_sha256,
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
        if isinstance(error, UsageLimitReached):
            state["usage_limit"] = True
    finally:
        try:
            state["finished_at"] = time.time()
            save_in_directory(attempt_descriptor, "state.json", state)
            save_in_directory(notes_descriptor, state_path.name, state)
        finally:
            if review_root_descriptor is not None:
                os.close(review_root_descriptor)
            os.close(attempt_descriptor)
            os.close(attempts_descriptor)
            os.close(notes_descriptor)
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
    runner.add_argument("--since-run")
    commands.add_parser("status")
    args = parser.parse_args()
    if args.action == "run":
        if not re.fullmatch(
            r"https://[A-Za-z0-9.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+/pull/[1-9][0-9]*",
            args.pr_url,
        ):
            parser.error("--pr-url must be an HTTPS pull request URL")
        if any(component in {".", ".."} for component in args.pr_url.split("/")[-4:-2]):
            parser.error("--pr-url must name an organization and repository")
        if not 0 < args.timeout < float("inf"):
            parser.error("--timeout must be a finite positive number of seconds")
    try:
        root = Path(
            git(Path.cwd(), "rev-parse", "--show-toplevel").decode().strip()
        ).resolve()
        notes = root / ".notes"
        if notes.is_symlink():
            raise ValueError("The review notes directory must not be a symlink")
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
