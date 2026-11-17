"""Process, lock, and file-safety helpers that go's review runners share."""

from contextlib import ExitStack
import fcntl
import hashlib
import json
import os
import signal
import stat
import subprocess
import uuid


PATHSPEC = ["--", ".", ":(exclude).notes"]
# A review child must start its own session, not join the parent harness's.
PARENT_SESSION_VARIABLES = [
    "CLAUDECODE",
    "CLAUDE_CODE_SESSION_ID",
    "CODEX_THREAD_ID",
    "DEBUG_SESSION_DIR",
]


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
    """Writes value atomically. A string is written as is, and anything else as JSON."""
    text = value if isinstance(value, str) else json.dumps(value, indent=2) + "\n"
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
            handle.write(text)
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
    # The CLI can exit while its child processes remain in its process group.
    try:
        os.killpg(process.pid, signal.SIGKILL)
    except ProcessLookupError:
        pass
    process.wait()


def interrupt(_signum, _frame):
    raise KeyboardInterrupt


def codex_result(attempt):
    """Reads a `codex exec --json` run's final message from result.json once its events show a completed turn."""
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
    return json.loads((attempt / "result.json").read_text())


def attempt_file_valid(state, state_path, attempts, name, path_key, sha_key):
    """Checks that state names its own attempt's file and that the file still has the recorded hash.

    The path walk follows no symlink, so a swapped directory or file fails the check.
    """
    run_id = state.get("run_id")
    if not isinstance(run_id, str):
        return False
    try:
        if str(uuid.UUID(run_id)) != run_id:
            return False
    except ValueError:
        return False
    if state.get(path_key) != str(state_path.parent / attempts / run_id / name):
        return False
    try:
        with ExitStack() as resources:
            directory = open_directory(state_path.parent)
            resources.callback(os.close, directory)
            for component in [attempts, run_id]:
                directory = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW,
                    dir_fd=directory,
                )
                resources.callback(os.close, directory)
            descriptor = os.open(name, os.O_RDONLY | os.O_NOFOLLOW, dir_fd=directory)
            artifact = resources.enter_context(os.fdopen(descriptor, "rb"))
            if not stat.S_ISREG(os.fstat(artifact.fileno()).st_mode):
                return False
            digest = hashlib.sha256()
            for chunk in iter(lambda: artifact.read(1024 * 1024), b""):
                digest.update(chunk)
            return digest.hexdigest() == state.get(sha_key)
    except OSError:
        return False
