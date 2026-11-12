#!/usr/bin/env python3
"""Bring up the PostHog stack on this worktree's own hogli devbox for go's Test plan step.

Run every subcommand from inside the posthog worktree. Each one prints one JSON
object on stdout and exits:
  0  success;
  3  not-run: the step cannot run until someone fixes the cause. The object holds
     `reason` (what failed) and `unblock` (the fix);
  1  unexpected error. The object holds `error`;
  2  usage error from argparse, with the message on stderr and no JSON.

Subcommands and their success fields:
  preflight     `workspace`, `label`, `user`, `status` (Coder's latest build status),
                and `app_health` (the health of the `app` app, or null when the box
                has no agent). It changes nothing.
  up --sha SHA  `workspace`, `label`, `sha` (the full HEAD SHA), `started_by_step`
                (whether `up` started a stopped box, which `down` then stops),
                `seeded_demo_data` (whether `up` ran `hogli dev:demo-data` because the
                user test@posthog.com did not exist), and `unmirrored_paths` (tracked
                files the sync does not mirror, which the parity check skips). It
                refuses (not-run, exit 3) a SHA other than local HEAD or a dirty tree
                before any devbox call. The Parity check and Box checkout sections
                below describe its checks on the box.
  forward       `url`, `port`, and `pid`. It kills the forward that the state file
                names, then serves the box's port 8010 at http://localhost:<port>
                through `coder port-forward --disable-autostart`, so a stopped box stays
                stopped. It uses FORWARD_PORT when it is free or else the first free port
                in FORWARD_FALLBACK_PORTS. A port is free when a TCP connect to 127.0.0.1
                and to ::1 is refused and both addresses bind, so a local server that
                listens on 0.0.0.0 or :: keeps its port; that check is what keeps the URL
                from reaching a local server. It refuses (not-run) when the forward process
                exits before /_health answers 200, or has exited one poll interval after
                the first 200, because coder exits when another process holds the port.
  down          `killed_forward` and `stopped_box`. It kills the recorded forward,
                stops the box only when `up` started it, and removes the state file.
                A failed stop keeps the state file, so a later `down` retries the stop.

State lives in .notes/go-test-plan/devbox.json (`workspace`, `label`,
`started_by_step`, `forward_pid`, `port`), and the forward's output goes to
.notes/go-test-plan/forward.log. The caller keeps .notes/ out of Git, because `up`
refuses a dirty tree.

Box guard. Every subcommand that acts on a box first proves that the box is the one
`hogli devbox:worktree` recorded for this worktree:
  - exactly one box is recorded in ~/.config/posthog/hogli_devbox_worktrees.json
    under an absolute path whose real path equals this worktree's real path;
  - the record's provider is coder and it carries Coder's workspace ID;
  - the box is named devbox-<coder user>-<label>, where <label> is a valid hogli
    label that does not end in the -eu region suffix, so it is never devbox-<user>
    or devbox-<user>-eu;
  - `coder list` shows exactly one box by that name, owned by the `coder whoami`
    user, with the recorded ID;
  - `coder list` shows no devbox-<user>-<label>-eu, because hogli resolves `-n <label>`
    to that box when the user prefers the EU region.
Every hogli call names the box with `-n <label>` and runs from the worktree. The
script never calls `devbox:worktree`, `devbox:clone`, `devbox:destroy`,
`devbox:worktree:teardown`, `coder ssh`, or any `coder` command that changes a box.
It calls `devbox:start` only on a box that Coder lists as stopped.

Parity check. `up` runs `git diff --quiet <sha>` in the box checkout against a
temporary index read from <sha>, so the box's own index does not matter and a file
the branch added after the first sync is not reported as deleted. The command goes
through `devbox:exec`, because `coder ssh` exits 0 whatever the remote command
returns. Tracked files that match the ignore paths in ~/.hogli/mutagen.yml never
reach the box, so the check excludes them and `up` reports them. The remote script
prints a sentinel for a match and another for a mismatch, because hogli itself exits
1 when it cannot reach the box, which is the exit code `git diff --quiet` uses for a
difference.

Box checkout. The box's copies of the paths the sync does not mirror come from the
commit the box checked out at its first sync (the box's `HEAD`), because the sync
mirrors neither `.git` nor those paths. Before the parity diff, the remote script
runs two checks against the box's `HEAD` and refuses (not-run, exit 3) when either
finds a path:
  - `git diff HEAD <sha>` over the ignore paths, commit to commit, lists each
    unmirrored path that differs, such as a file that the branch added, changed, or
    deleted, or that main changed after the first sync and the branch picked up
    through a rebase. It reads commits only, so a build on the box that rewrites one
    of those files does not trip it. It prints UNMIRRORED_STALE_SENTINEL followed by
    one path per line.
  - `git diff --diff-filter=D HEAD <sha>` outside the ignore paths lists each mirrored
    file that the box's `HEAD` tracks and SHA does not. Each one that is still a file
    or a symlink in the box checkout is listed, because mutagen's one-way-safe mode
    keeps a file that only the box has, so a deleted migration or module would stay on
    the box while the parity diff skips it as untracked. A file that the box created
    and no commit tracks, and a path that SHA turned into a directory, pass. It prints
    KEPT_DELETED_SENTINEL followed by one path per line.
A name in either list that holds a newline makes the script fail the comparison,
because the unblock passes these names to `git restore` and `rm`. Otherwise the
remote script exits BOX_CHECKOUT_STALE_EXIT. The reason names every path. The
unblock gives one command that restores the unmirrored paths from SHA on the box,
removes the kept files, and moves the box's checkout to SHA, because
`devbox:sync --checkout-branch` acts only when it creates a sync. One command repairs
both, because moving the checkout to SHA empties both lists, so a kept file that a
separate refusal left for later would never be listed again. The helper gives this
reason only when it sees that exit code, a sentinel, and at least one path under one;
any other result refuses as a failed comparison.

`forward` and `down` kill a forward only when `ps` shows `port-forward` and the
recorded workspace in that PID's command line, so a reused PID survives. They signal
no process whose command line `ps` did not read. When any `ps` call does not answer
within PS_TIMEOUT, they leave the state file as it was and refuse with not-run.
"""

import argparse
import errno
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import time
import urllib.request


WHOAMI_TIMEOUT = 20
LIST_TIMEOUT = 30
HOGLI_HELP_TIMEOUT = 60
START_TIMEOUT = 20 * 60
SYNC_TIMEOUT = 60
SYNC_FLUSH_TIMEOUT = 5 * 60
TREE_CHECK_TIMEOUT = 2 * 60
USER_CHECK_TIMEOUT = 2 * 60
DEMO_DATA_TIMEOUT = 15 * 60
STACK_UP_TIMEOUT = 15 * 60
STACK_WAIT_TIMEOUT = 12 * 60
APP_HEALTH_TIMEOUT = 20 * 60
APP_HEALTH_POLL_INTERVAL = 15
FORWARD_HEALTH_TIMEOUT = 2 * 60
FORWARD_POLL_INTERVAL = 0.5
FORWARD_EXIT_TIMEOUT = 10
STOP_TIMEOUT = 5 * 60
LOCAL_TIMEOUT = 60
PS_TIMEOUT = 10
FORWARD_PORT = 8010
BOX_APP_PORT = 8010
FORWARD_FALLBACK_PORTS = range(18010, 18100)

CODER_URL = "https://coder.dev.posthog.dev"
RECORDS_PATH = Path(".config/posthog/hogli_devbox_worktrees.json")
MUTAGEN_CONFIG_PATH = Path(".hogli/mutagen.yml")
STATE_DIR = Path(".notes/go-test-plan")
APP_SLUG = "app"
TEST_USER = "test@posthog.com"
LABEL_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?$")
REGION_SUFFIX = "eu"
TREE_MATCH_SENTINEL = "DEVBOX_TREE_MATCHES_HEAD"
TREE_DIFFERS_SENTINEL = "DEVBOX_TREE_DIFFERS_FROM_HEAD"
UNMIRRORED_STALE_SENTINEL = "DEVBOX_UNMIRRORED_DIFFERS_FROM_HEAD"
KEPT_DELETED_SENTINEL = "DEVBOX_BOX_KEEPS_FILES_HEAD_DELETES"
USER_SENTINEL = "DEVBOX_TEST_USER_EXISTS="
FETCH_FAILED_EXIT = 10
BOX_CHECKOUT_STALE_EXIT = 11


class NotRun(Exception):
    def __init__(self, reason, unblock):
        super().__init__(reason)
        self.reason = reason
        self.unblock = unblock


def run(argv, timeout, cwd=None):
    """Run argv with no stdin and kill its whole process group when it outlives timeout.

    hogli starts `coder` and `mutagen` children that hold the output pipes.
    Killing only the direct child would leave the read blocked.
    """
    process = subprocess.Popen(
        argv,
        cwd=cwd,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
        start_new_session=True,
    )
    try:
        stdout, stderr = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        kill_group(process.pid, signal.SIGKILL)
        try:
            process.communicate(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        raise NotRun(
            f"`{display(argv)}` did not finish within {timeout} seconds",
            f"check the box and the network, then run /go again; `{display(argv)}` shows where it stops",
        )
    return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)


def kill_group(pid, sig):
    try:
        os.killpg(pid, sig)
    except (ProcessLookupError, PermissionError):
        pass


def display(argv):
    text = shlex.join(["bin/hogli" if argv[0].endswith("/bin/hogli") else argv[0], *argv[1:]])
    return text if len(text) <= 200 else text[:200] + "…"


def last_text_line(text):
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    return lines[-1] if lines else "no output"


def last_line(result):
    return last_text_line(result.stderr + "\n" + result.stdout)


def toplevel():
    try:
        result = run(["git", "rev-parse", "--show-toplevel"], LOCAL_TIMEOUT)
    except FileNotFoundError:
        raise NotRun("git is not on PATH", "install git")
    if result.returncode != 0:
        raise NotRun("the current directory is not inside a Git worktree", "run the helper from the posthog worktree")
    return Path(result.stdout.strip()).resolve()


def git(top, *args):
    result = run(["git", "-C", str(top), *args], LOCAL_TIMEOUT)
    if result.returncode != 0:
        raise RuntimeError(f"git {' '.join(args)} failed: {last_line(result)}")
    return result.stdout


def hogli(top, *args, timeout):
    return run([str(top / "bin/hogli"), *args], timeout, cwd=top)


def worktree_unblock(top):
    return f"run `bin/hogli devbox:worktree --start-app -y` in {top}"


def coder_user():
    if shutil.which("coder") is None:
        raise NotRun("the `coder` CLI is not on PATH", "run `bin/hogli devbox:setup` in the posthog worktree")
    login = f"run `coder login {CODER_URL}`"
    result = run(["coder", "whoami", "--output", "json"], WHOAMI_TIMEOUT)
    if result.returncode != 0:
        raise NotRun(f"`coder whoami` failed: {last_line(result)}", login)
    try:
        user = json.loads(result.stdout)[0]["username"]
        if not isinstance(user, str) or not user:
            raise ValueError
    except (ValueError, LookupError, TypeError):
        raise NotRun("`coder whoami` printed no username", login)
    return user.lower()


def list_workspaces():
    result = run(["coder", "list", "--output", "json"], LIST_TIMEOUT)
    unblock = f"check that `coder list` works, or run `coder login {CODER_URL}`"
    if result.returncode != 0:
        raise NotRun(f"`coder list` failed: {last_line(result)}", unblock)
    try:
        workspaces = json.loads(result.stdout)
    except ValueError:
        raise NotRun("`coder list` printed no JSON", unblock)
    if not isinstance(workspaces, list) or not all(isinstance(entry, dict) for entry in workspaces):
        raise NotRun("`coder list` printed an unexpected shape", unblock)
    return workspaces


def recorded_box(top):
    unblock = worktree_unblock(top)
    path = Path.home() / RECORDS_PATH
    try:
        records = json.loads(path.read_text())
    except FileNotFoundError:
        raise NotRun(f"hogli has recorded no devbox for any worktree ({path} does not exist)", unblock)
    except (OSError, ValueError):
        raise NotRun(f"{path} is not valid JSON", unblock)
    if not isinstance(records, dict):
        raise NotRun(f"{path} is not a map of worktree paths to records", unblock)
    matches = []
    for key, record in records.items():
        if not os.path.isabs(key) or Path(os.path.realpath(key)) != top:
            continue
        if not isinstance(record, dict):
            raise NotRun(f"the record for {key} in {path} is not an object", unblock)
        workspace, git_dir = record.get("workspace"), record.get("git_dir")
        if not (isinstance(workspace, str) and workspace and isinstance(git_dir, str) and git_dir):
            raise NotRun(f"the record for {key} in {path} has no workspace or git_dir", unblock)
        matches.append((workspace, record.get("workspace_id"), record.get("provider", "coder")))
    if not matches:
        raise NotRun(f"hogli has recorded no devbox for {top}", unblock)
    if len(set(matches)) != 1:
        names = ", ".join(sorted({match[0] for match in matches}))
        raise NotRun(f"{path} records more than one devbox for {top}: {names}", unblock)
    workspace, workspace_id, provider = matches[0]
    if provider != "coder":
        raise NotRun(f"the devbox for {top} runs on {provider!r}, not Coder", unblock)
    if not isinstance(workspace_id, str) or not workspace_id:
        raise NotRun(f"the record for {top} has no Coder workspace ID, so it cannot prove which box is its own", unblock)
    return workspace, workspace_id


def is_valid_label(label):
    return bool(LABEL_RE.match(label)) and label != REGION_SUFFIX and not label.endswith("-" + REGION_SUFFIX)


def describe(workspace):
    build = workspace.get("latest_build") if isinstance(workspace.get("latest_build"), dict) else {}
    health = None
    for resource in build.get("resources") or []:
        for agent in resource.get("agents") or []:
            for app in agent.get("apps") or []:
                if app.get("slug") == APP_SLUG:
                    health = app.get("health")
    return build.get("status"), health


def find_listed(box, workspaces):
    """Return the one listed workspace that matches the guarded box, or refuse."""
    unblock = worktree_unblock(box["top"])
    named = [entry for entry in workspaces if entry.get("name") == box["workspace"]]
    if len(named) != 1:
        raise NotRun(f"Coder lists no single workspace named {box['workspace']}", unblock)
    listed = named[0]
    if listed.get("owner_name") != box["user"]:
        raise NotRun(f"{box['workspace']} belongs to {listed.get('owner_name')!r}, not {box['user']}", unblock)
    if listed.get("id") != box["workspace_id"]:
        raise NotRun(
            f"{box['workspace']} is not the box hogli recorded for this worktree (its Coder ID differs, so it was recreated)",
            unblock,
        )
    twin = f"{box['workspace']}-{REGION_SUFFIX}"
    if any(entry.get("name") == twin for entry in workspaces):
        raise NotRun(
            f"Coder also lists {twin}, and `-n {box['label']}` resolves to it when hogli's saved region is EU",
            f"rename or destroy {twin} yourself, then run /go again",
        )
    return listed


def resolve_box(top):
    """Prove which box is this worktree's own and return it with its listed workspace."""
    user = coder_user()
    workspace, workspace_id = recorded_box(top)
    prefix = f"devbox-{user}-"
    label = workspace[len(prefix):] if workspace.startswith(prefix) else ""
    if not is_valid_label(label):
        raise NotRun(f"{workspace} is not a labeled devbox of the Coder user {user}", worktree_unblock(top))
    box = {"top": top, "user": user, "workspace": workspace, "workspace_id": workspace_id, "label": label}
    return box, find_listed(box, list_workspaces())


def check_tools(top):
    if shutil.which("npx") is None:
        raise NotRun("`npx` is not on PATH, so the browser server cannot start", "install Node.js")
    script = top / "bin/hogli"
    if not os.access(script, os.X_OK):
        raise NotRun(f"{script} does not exist", "run the step from a posthog worktree")
    result = hogli(top, "--help", timeout=HOGLI_HELP_TIMEOUT)
    if result.returncode != 0:
        raise NotRun(f"`bin/hogli --help` failed: {last_line(result)}", f"run `flox activate` or `uv sync` in {top}")


def preflight(args):
    top = toplevel()
    check_tools(top)
    box, listed = resolve_box(top)
    status, health = describe(listed)
    return {"workspace": box["workspace"], "label": box["label"], "user": box["user"], "status": status, "app_health": health}


def state_path(top):
    return top / STATE_DIR / "devbox.json"


def read_state(top):
    try:
        state = json.loads(state_path(top).read_text())
    except FileNotFoundError:
        return None
    if not isinstance(state, dict):
        raise RuntimeError(f"{state_path(top)} does not hold a JSON object")
    return state


def write_state(top, state):
    path = state_path(top)
    path.parent.mkdir(parents=True, exist_ok=True)
    staging = tempfile.NamedTemporaryFile("w", dir=path.parent, prefix="devbox.", suffix=".tmp", delete=False)
    try:
        with staging:
            staging.write(json.dumps(state, indent=2) + "\n")
        os.replace(staging.name, path)
    except BaseException:
        Path(staging.name).unlink(missing_ok=True)
        raise


def clear_forward(top, state):
    state.update(forward_pid=None, port=None)
    write_state(top, state)


def ignore_pathspecs(patterns):
    """Translate mutagen ignore paths into Git glob pathspecs that match the same files.

    Mutagen matches a pattern without a slash against the name at any depth, and a
    pattern with a slash against the path from the sync root. A match on a directory
    covers everything under it.
    """
    specs = []
    for pattern in patterns:
        if not pattern or pattern.startswith("!"):
            return None
        directory_only = pattern.endswith("/")
        body = pattern.strip("/")
        if not body:
            return None
        if "/" not in pattern.rstrip("/"):
            body = "**/" + body
        if not directory_only:
            specs.append(f":(glob){body}")
        specs.append(f":(glob){body}/**")
    return specs


def mutagen_ignore_paths(path):
    """Read the `ignore: paths:` list from a mutagen YAML file, or None when the file has another shape."""
    lines = path.read_text().splitlines()
    patterns = []
    paths_indent = None
    for line in lines:
        stripped = line.strip()
        if not stripped or stripped.startswith("#"):
            continue
        indent = len(line) - len(line.lstrip())
        if paths_indent is None:
            if stripped == "paths:":
                paths_indent = indent
            elif stripped.startswith("paths:"):
                return None
            continue
        if indent <= paths_indent:
            break
        if not stripped.startswith("- "):
            return None
        item = stripped[2:].strip()
        if len(item) >= 2 and item[0] == item[-1] and item[0] in "'\"":
            item = item[1:-1]
        elif "#" in item:
            item = item.split(" #", 1)[0].strip()
        patterns.append(item)
    return patterns


def unmirrored_specs():
    """Return Git pathspecs for the paths the sync does not mirror, or refuse."""
    path = Path.home() / MUTAGEN_CONFIG_PATH
    unblock = f"restore {path}; hogli seeds it from tools/hogli-commands/hogli_commands/devbox/mutagen_defaults.yml"
    try:
        patterns = mutagen_ignore_paths(path)
    except OSError:
        raise NotRun(f"cannot read the sync's ignore list in {path}", unblock)
    specs = None if patterns is None else ignore_pathspecs(patterns)
    if specs is None:
        raise NotRun(f"{path} has an ignore list this helper cannot translate", unblock)
    return specs


def git_paths(top, *args):
    return sorted(name for name in git(top, *args).split("\0") if name)


def listed_paths_script(diff, sentinel, test):
    """Return shell that prints sentinel, then each path that `git diff <diff>` lists and test accepts, one per line.

    It sets `stale` when it prints a path. The script exits 2 when a path holds a newline.
    """
    return (
        f'git diff --name-only -z --no-renames {diff} > "$listing" || exit 2\n'
        "printed=0\n"
        "while IFS= read -r -d '' path; do\n"
        "  case $path in *$'\\n'*) exit 2 ;; esac\n"
        f"  {test} || continue\n"
        f'  [ "$printed" -eq 1 ] || echo {sentinel}\n'
        "  printed=1\n"
        "  stale=1\n"
        "  printf '%s\\n' \"$path\"\n"
        'done < "$listing"\n'
    )


def tree_check_script(sha, specs, excluded):
    excludes = " ".join(shlex.quote(f":(exclude,literal){name}") for name in excluded)
    unmirrored_excludes = " ".join(shlex.quote(":(exclude," + spec[len(":("):]) for spec in specs)
    stale_check = ""
    if specs:
        quoted = " ".join(shlex.quote(spec) for spec in specs)
        stale_check = listed_paths_script(f"HEAD {sha} -- {quoted}", UNMIRRORED_STALE_SENTINEL, "true")
    kept_check = listed_paths_script(
        f"--diff-filter=D HEAD {sha} -- {unmirrored_excludes}", KEPT_DELETED_SENTINEL, '{ [ -f "$path" ] || [ -L "$path" ]; }'
    )
    return (
        "cd ~/posthog || exit 2\n"
        f"git cat-file -e {sha}^{{commit}} 2>/dev/null || git fetch -q origin {sha} || exit {FETCH_FAILED_EXIT}\n"
        'index=$(mktemp) || exit 2\n'
        'listing=$(mktemp) || { rm -f "$index"; exit 2; }\n'
        'trap \'rm -f "$index" "$listing"\' EXIT\n'
        "stale=0\n"
        + stale_check
        + kept_check
        + f'[ "$stale" -eq 0 ] || exit {BOX_CHECKOUT_STALE_EXIT}\n'
        f'GIT_INDEX_FILE="$index" git read-tree {sha} || exit 2\n'
        f'GIT_INDEX_FILE="$index" git diff --quiet {sha} -- {excludes}\n'
        "status=$?\n"
        f'[ "$status" -eq 0 ] && echo {TREE_MATCH_SENTINEL}\n'
        f'[ "$status" -eq 1 ] && echo {TREE_DIFFERS_SENTINEL}\n'
        'exit "$status"\n'
    )


def stale_checkout_paths(output):
    """Return the paths listed under the unmirrored-stale sentinel and those listed under the kept-deleted sentinel."""
    sections = {UNMIRRORED_STALE_SENTINEL: [], KEPT_DELETED_SENTINEL: []}
    current = None
    for line in output.splitlines():
        if line.strip() in sections:
            current = sections[line.strip()]
        elif current is not None and line.strip():
            current.append(line)
    return sections[UNMIRRORED_STALE_SENTINEL], sections[KEPT_DELETED_SENTINEL]


def refuse_stale_checkout(top, box, sha, stale, kept):
    reasons, commands, effects = [], ["cd ~/posthog"], []
    if stale:
        reasons.append(
            f"the box serves files that the sync does not mirror from the commit it checked out at its first sync, and they differ from HEAD {sha[:10]}: {', '.join(stale)}"
        )
        commands.append(f"git restore --source={sha} --worktree -- {shlex.join(stale)}")
        effects.append(f"restores those unmirrored files from {sha[:10]}")
    if kept:
        reasons.append(
            f"the box still has files that its checked-out commit tracks and HEAD {sha[:10]} deletes, which the sync does not remove: {', '.join(kept)}"
        )
        commands.append(f"rm -f -- {shlex.join(kept)}")
        effects.append("removes the files that HEAD deletes")
    commands.append(f"git reset -q {sha}")
    effects.append(f"moves the box's checkout to {sha[:10]}")
    repair = " && ".join(commands)
    raise NotRun(
        "; ".join(reasons),
        f"run `bin/hogli devbox:exec -n {box['label']} -- bash -c {shlex.quote(repair)}` in {top}, which {', '.join(effects[:-1])} and {effects[-1]} on the box, then run /go again",
    )


def check_tree(top, box, sha, specs, excluded):
    result = hogli(
        top, "devbox:exec", "-n", box["label"], "--", "bash", "-c", tree_check_script(sha, specs, excluded),
        timeout=TREE_CHECK_TIMEOUT,
    )
    if result.returncode == BOX_CHECKOUT_STALE_EXIT:
        stale, kept = stale_checkout_paths(result.stdout)
        if stale or kept:
            refuse_stale_checkout(top, box, sha, stale, kept)
    if result.returncode == 0 and TREE_MATCH_SENTINEL in result.stdout.split():
        return
    if result.returncode == 1 and TREE_DIFFERS_SENTINEL in result.stdout.split():
        raise NotRun(
            f"box checkout does not match HEAD {sha[:10]} after the sync flush",
            f"run `bin/hogli devbox:sync -n {box['label']} --status` in {top} and resolve what differs",
        )
    if result.returncode == FETCH_FAILED_EXIT:
        raise NotRun(f"the box cannot fetch {sha[:10]} from origin, so it cannot compare its checkout with HEAD", "push the branch")
    raise NotRun(
        f"could not compare the box checkout with HEAD (exit {result.returncode}): {last_line(result)}",
        f"check `bin/hogli devbox:exec -n {box['label']} -- git -C ~/posthog status` in {top}",
    )


def sync_box(top, box):
    label = box["label"]
    unblock = f"run `bin/hogli devbox:sync -n {label} --status` in {top} and fix the sync"
    for flag, timeout in (("--resume", SYNC_TIMEOUT), ("--flush", SYNC_FLUSH_TIMEOUT)):
        result = hogli(top, "devbox:sync", "-n", label, flag, timeout=timeout)
        if result.returncode != 0:
            raise NotRun(f"`devbox:sync {flag}` failed: {last_line(result)}", unblock)
    result = hogli(top, "devbox:sync", "-n", label, "--json", timeout=SYNC_TIMEOUT)
    try:
        sessions = json.loads(result.stdout) if result.returncode == 0 else None
    except ValueError:
        sessions = None
    if not isinstance(sessions, list) or len(sessions) != 1 or not isinstance(sessions[0], dict):
        raise NotRun(f"`devbox:sync --json` shows no single sync session for {box['workspace']}", unblock)
    session = sessions[0]
    if session.get("paused") is not False:
        raise NotRun(f"the sync to {box['workspace']} is paused", unblock)
    conflicts = session.get("conflicts")
    if type(conflicts) is not int or conflicts != 0:
        raise NotRun(f"the sync to {box['workspace']} reports conflicts: {conflicts!r}", unblock)
    alpha = session.get("alpha")
    if not isinstance(alpha, str) or not os.path.isabs(alpha) or Path(os.path.realpath(alpha)) != top:
        raise NotRun(f"the sync to {box['workspace']} mirrors {alpha!r}, not {top}", unblock)


def start_box(top, box, state):
    state["started_by_step"] = True
    write_state(top, state)
    result = hogli(top, "devbox:start", "-n", box["label"], timeout=START_TIMEOUT)
    if result.returncode != 0:
        raise NotRun(
            f"`devbox:start -n {box['label']}` failed: {last_line(result)}",
            f"run `bin/hogli devbox:start -n {box['label']}` in {top}",
        )
    status, _ = describe(find_listed(box, list_workspaces()))
    if status != "running":
        raise NotRun(f"{box['workspace']} is {status} after `devbox:start`", f"run `bin/hogli devbox:start -n {box['label']}` in {top}")


def remote_flox(top, box, command, timeout):
    return hogli(top, "devbox:exec", "-n", box["label"], "--flox", "--", *command, timeout=timeout)


def stack_up(top, box):
    script = (
        "cd ~/posthog && { ./bin/hogli stop || true; } && ./bin/hogli up -d -y"
        f" && ./bin/hogli wait --timeout {STACK_WAIT_TIMEOUT} --json"
    )
    result = remote_flox(top, box, ["bash", "-c", script], STACK_UP_TIMEOUT)
    if result.returncode != 0:
        raise NotRun(
            f"the stack on {box['workspace']} did not come up: {last_line(result)}",
            f"run `bin/hogli devbox:exec -n {box['label']} --flox -- ./bin/hogli up` in {top} and read its output",
        )


def wait_for_app(top, box):
    deadline = time.monotonic() + APP_HEALTH_TIMEOUT
    health = None
    while True:
        try:
            workspaces = list_workspaces()
        except NotRun:
            workspaces = None
        if workspaces is not None:
            status, health = describe(find_listed(box, workspaces))
            if status != "running":
                raise NotRun(f"{box['workspace']} became {status} while the app started", f"run `bin/hogli devbox:start -n {box['label']}` in {top}")
            if health == "healthy":
                return
        if time.monotonic() >= deadline:
            raise NotRun(
                f"the `app` app on {box['workspace']} did not turn healthy within {APP_HEALTH_TIMEOUT} seconds (last: {health})",
                f"run `bin/hogli devbox:exec -n {box['label']} --flox -- ./bin/hogli wait` in {top} and check the stack",
            )
        time.sleep(APP_HEALTH_POLL_INTERVAL)


def test_user_exists(top, box):
    code = (
        "from posthog.models import User; "
        f"print({USER_SENTINEL!r} + str(User.objects.filter(email={TEST_USER!r}).exists()))"
    )
    result = remote_flox(top, box, ["python", "manage.py", "shell", "-c", code], USER_CHECK_TIMEOUT)
    answers = [line.strip()[len(USER_SENTINEL):] for line in result.stdout.splitlines() if line.strip().startswith(USER_SENTINEL)]
    if result.returncode != 0 or answers not in (["True"], ["False"]):
        raise NotRun(
            f"could not check whether {TEST_USER} exists on {box['workspace']}: {last_line(result)}",
            f"run `bin/hogli devbox:exec -n {box['label']} --flox -- python manage.py shell` in {top} and check the database",
        )
    return answers == ["True"]


def seed_demo_data(top, box):
    result = remote_flox(top, box, ["./bin/hogli", "dev:demo-data"], DEMO_DATA_TIMEOUT)
    if result.returncode != 0:
        raise NotRun(
            f"`hogli dev:demo-data` failed on {box['workspace']}: {last_line(result)}",
            f"run `bin/hogli devbox:exec -n {box['label']} --flox -- ./bin/hogli dev:demo-data` in {top}",
        )


def resolve_commit(top, revision):
    result = run(["git", "-C", str(top), "rev-parse", "--verify", "--quiet", "--end-of-options", f"{revision}^{{commit}}"], LOCAL_TIMEOUT)
    return result.stdout.strip() if result.returncode == 0 else None


def up(args):
    top = toplevel()
    if git(top, "status", "--porcelain", "--untracked-files=all").strip():
        raise NotRun("the local tree has uncommitted or untracked files", "commit or remove them, then run /go again")
    head = git(top, "rev-parse", "HEAD").strip()
    if resolve_commit(top, args.sha) != head:
        raise NotRun(f"{args.sha} is not local HEAD {head[:10]}", "run the step again at the current HEAD")
    check_tools(top)
    box, listed = resolve_box(top)
    specs = unmirrored_specs()
    excluded = git_paths(top, "ls-files", "-z", "--", *specs) if specs else []

    state = read_state(top) or {}
    if state and state.get("workspace") != box["workspace"]:
        raise NotRun(
            f"{state_path(top)} names {state.get('workspace')!r}, not {box['workspace']}",
            "run `devbox-stack.py down` first",
        )
    state = {
        "workspace": box["workspace"],
        "label": box["label"],
        "started_by_step": state.get("started_by_step") is True,
        "forward_pid": state.get("forward_pid"),
        "port": state.get("port"),
    }
    write_state(top, state)

    status, _ = describe(listed)
    if status == "stopped":
        start_box(top, box, state)
    elif status != "running":
        raise NotRun(f"{box['workspace']} is {status}", "wait for Coder to finish its current build, then run /go again")
    sync_box(top, box)
    check_tree(top, box, head, specs, excluded)
    stack_up(top, box)
    wait_for_app(top, box)
    seeded = False
    if not test_user_exists(top, box):
        seed_demo_data(top, box)
        seeded = True
    return {
        "workspace": box["workspace"],
        "label": box["label"],
        "sha": head,
        "started_by_step": state["started_by_step"],
        "seeded_demo_data": seeded,
        "unmirrored_paths": excluded,
    }


def require_state_box(top, state):
    box, _ = resolve_box(top)
    if state.get("workspace") != box["workspace"] or state.get("label") != box["label"]:
        raise NotRun(
            f"{state_path(top)} names {state.get('workspace')!r}, which is not this worktree's box {box['workspace']}",
            f"stop that box yourself if the step started it, then delete {state_path(top)}",
        )
    return box


def process_line(pid, field):
    try:
        result = run(["ps", "-ww", "-o", f"{field}=", "-p", str(pid)], PS_TIMEOUT)
    except NotRun:
        raise NotRun(
            f"`ps` did not report the {field} of process {pid} within {PS_TIMEOUT} seconds, so the helper cannot tell whether that process is the recorded forward",
            f"if `ps -o command= -p {pid}` shows `coder port-forward`, kill {pid}; then run /go again",
        )
    return result.stdout.strip()


def process_gone(pid):
    stat = process_line(pid, "stat")
    return not stat or stat.startswith("Z")


def stop_forward(state):
    """Kill the recorded forward when its command line proves it is ours, and report whether it did."""
    pid = state.get("forward_pid")
    if type(pid) is not int or pid <= 0:
        return False
    command = process_line(pid, "command").split()
    if not any("port-forward" in token for token in command) or state.get("workspace") not in command:
        return False
    for sig in (signal.SIGTERM, signal.SIGKILL):
        try:
            if os.getpgid(pid) == pid:
                os.killpg(pid, sig)
            else:
                os.kill(pid, sig)
        except (ProcessLookupError, PermissionError):
            return True
        deadline = time.monotonic() + FORWARD_EXIT_TIMEOUT
        while time.monotonic() < deadline:
            if process_gone(pid):
                return True
            time.sleep(0.05)
    return process_gone(pid)


def port_is_free(port):
    """Return whether nothing answers a TCP connect on the port and both loopback addresses bind it.

    The bind alone misses a listener on 0.0.0.0 or ::, because macOS lets a socket with
    SO_REUSEADDR bind a loopback address that a wildcard listener already covers. The bind
    sets SO_REUSEADDR anyway, as hogli's `_local_port_is_available` does. A port that
    only has connections in TIME_WAIT therefore counts as free.
    """
    for host in ("127.0.0.1", "::1"):
        family = socket.AF_INET6 if ":" in host else socket.AF_INET
        try:
            with socket.socket(family, socket.SOCK_STREAM) as sock:
                sock.settimeout(1)
                outcome = sock.connect_ex((host, port))
        except OSError as error:
            outcome = error.errno
        if outcome in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL, errno.ENETUNREACH):
            continue
        if outcome != errno.ECONNREFUSED:
            return False
        try:
            with socket.socket(family, socket.SOCK_STREAM) as sock:
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
                sock.bind((host, port))
        except OSError as error:
            if error.errno in (errno.EAFNOSUPPORT, errno.EADDRNOTAVAIL):
                continue
            return False
    return True


def serves_health(port):
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(f"http://127.0.0.1:{port}/_health", timeout=2) as response:
            return response.status == 200
    except OSError:
        return False


def forward(args):
    top = toplevel()
    state = read_state(top)
    if state is None:
        raise NotRun(f"{state_path(top)} does not exist", "run `devbox-stack.py up` first")
    box = require_state_box(top, state)
    stop_forward(state)
    clear_forward(top, state)
    port = next((port for port in (FORWARD_PORT, *FORWARD_FALLBACK_PORTS) if port_is_free(port)), None)
    if port is None:
        raise NotRun(
            f"ports {FORWARD_PORT} and {min(FORWARD_FALLBACK_PORTS)} to {max(FORWARD_FALLBACK_PORTS)} are all in use",
            "free one of those local ports",
        )
    log_path = top / STATE_DIR / "forward.log"
    with open(log_path, "w") as log:
        process = subprocess.Popen(
            ["coder", "port-forward", box["workspace"], "--disable-autostart", f"--tcp={port}:{BOX_APP_PORT}"],
            cwd=top,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
    state.update(forward_pid=process.pid, port=port)
    write_state(top, state)

    def refuse(reason, unblock):
        kill_group(process.pid, signal.SIGKILL)
        process.wait()
        clear_forward(top, state)
        raise NotRun(f"{reason}: {last_text_line(log_path.read_text())}", unblock)

    deadline = time.monotonic() + FORWARD_HEALTH_TIMEOUT
    while not serves_health(port):
        if process.poll() is not None or time.monotonic() >= deadline:
            refuse(
                f"`coder port-forward {box['workspace']}` did not serve /_health on port {port}",
                f"check that the stack on {box['workspace']} answers /_health, then run /go again",
            )
        time.sleep(FORWARD_POLL_INTERVAL)
    # coder exits when it cannot bind the port. A 200 followed by coder's exit came from another local server.
    time.sleep(FORWARD_POLL_INTERVAL)
    if process.poll() is not None:
        refuse(
            f"`coder port-forward {box['workspace']}` exited after /_health answered on port {port}, so another local process serves that port",
            f"stop the local process that listens on port {port} (`lsof -nP -iTCP:{port} -sTCP:LISTEN` names it), then run /go again",
        )
    return {"url": f"http://localhost:{port}", "port": port, "pid": process.pid}


def down(args):
    top = toplevel()
    state = read_state(top)
    if state is None:
        return {"killed_forward": False, "stopped_box": False}
    killed = stop_forward(state)
    clear_forward(top, state)
    stopped = False
    if state.get("started_by_step") is True:
        box = require_state_box(top, state)
        result = hogli(top, "devbox:stop", "-n", box["label"], timeout=STOP_TIMEOUT)
        if result.returncode != 0:
            raise NotRun(
                f"`devbox:stop -n {box['label']}` failed: {last_line(result)}",
                f"run `bin/hogli devbox:stop -n {box['label']}` in {top}",
            )
        stopped = True
    state_path(top).unlink()
    return {"killed_forward": killed, "stopped_box": stopped}


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("preflight", help="check tools, Coder login, and the box guard; change nothing").set_defaults(handler=preflight)
    up_parser = commands.add_parser("up", help="bring the box and its stack to local HEAD")
    up_parser.add_argument("--sha", required=True, help="local HEAD; the helper refuses any other commit")
    up_parser.set_defaults(handler=up)
    commands.add_parser("forward", help="serve the box's app on a local port").set_defaults(handler=forward)
    commands.add_parser("down", help="kill the forward and stop a box that up started").set_defaults(handler=down)
    args = parser.parse_args(argv)
    try:
        payload = args.handler(args)
    except NotRun as refusal:
        print(json.dumps({"reason": refusal.reason, "unblock": refusal.unblock}))
        return 3
    except Exception as error:
        print(json.dumps({"error": f"{type(error).__name__}: {error}"}))
        return 1
    print(json.dumps(payload))
    return 0


if __name__ == "__main__":
    sys.exit(main())
