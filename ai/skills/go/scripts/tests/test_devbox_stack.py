import http.server
import importlib.util
import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import socket
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest
import urllib.request
import uuid


SCRIPT = Path(__file__).resolve().parents[1] / "devbox-stack.py"
USER = "philh"
LABEL = "go-test-plan"
WORKSPACE = f"devbox-{USER}-{LABEL}"
MAIN_BOX = f"devbox-{USER}"
EU_MAIN_BOX = f"devbox-{USER}-eu"
CODER_LOGIN_UNBLOCK = "coder login https://coder.dev.posthog.dev"
NEVER_CALLED_HOGLI = {"devbox:worktree", "devbox:clone", "devbox:destroy", "devbox:worktree:teardown"}
# `coder ssh` exits 0 whatever the remote command returns (hogli coder.py exec_replace).
# `coder ssh` also starts a stopped box.
NEVER_CALLED_CODER = {"login", "create", "delete", "start", "stop", "restart", "update", "ssh"}
SPEC_CONSTANTS = {
    "WHOAMI_TIMEOUT": 20,
    "LIST_TIMEOUT": 30,
    "HOGLI_HELP_TIMEOUT": 60,
    "START_TIMEOUT": 20 * 60,
    "SYNC_FLUSH_TIMEOUT": 5 * 60,
    "TREE_CHECK_TIMEOUT": 2 * 60,
    "USER_CHECK_TIMEOUT": 2 * 60,
    "DEMO_DATA_TIMEOUT": 15 * 60,
    "STACK_UP_TIMEOUT": 15 * 60,
    "APP_HEALTH_TIMEOUT": 20 * 60,
    "APP_HEALTH_POLL_INTERVAL": 15,
    "FORWARD_HEALTH_TIMEOUT": 2 * 60,
    "STOP_TIMEOUT": 5 * 60,
    "FORWARD_PORT": 8010,
}
# The full run starts from a stopped box whose sync is paused and whose app has no test user.
# The list omits calls to `bin/hogli --help`. How often `up` repeats the preflight is not part of the contract.
EXPECTED_FLOW_HOGLI_LOG = [
    ("devbox:start", "-n", LABEL),
    ("devbox:sync", "-n", LABEL, "--resume"),
    ("devbox:sync", "-n", LABEL, "--flush"),
    ("devbox:sync", "-n", LABEL, "--json"),
    ("devbox:exec", "-n", LABEL, "<tree-check>"),
    ("devbox:exec", "-n", LABEL, "<stack-up>"),
    ("devbox:exec", "-n", LABEL, "<user-check>"),
    ("devbox:exec", "-n", LABEL, "<demo-data>"),
    ("devbox:stop", "-n", LABEL),
]

# Loads the script as a module, replaces the named module constants, and calls main(argv).
# A constant the script does not define exits 99. A renamed constant therefore fails the test.
BOOTSTRAP = textwrap.dedent(
    """
    import importlib.util
    import json
    import sys

    script, overrides = sys.argv[1], json.loads(sys.argv[2])
    spec = importlib.util.spec_from_file_location("devbox_stack", script)
    module = importlib.util.module_from_spec(spec)
    sys.modules["devbox_stack"] = module
    spec.loader.exec_module(module)
    for name, value in overrides.items():
        if not hasattr(module, name):
            print(f"devbox-stack.py has no module constant {name}", file=sys.stderr)
            sys.exit(99)
        setattr(module, name, value)
    sys.exit(module.main(sys.argv[3:]))
    """
)

# One source serves as the fake `coder`, `npx`, and `bin/hogli`. It reads and writes world.json.
# A `devbox:start` therefore shows up as a running box in the next `coder list`.
FAKE = r'''
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

ROOT = Path(ROOT_PATH)
WORLD = ROOT / "world.json"
TOOL = Path(sys.argv[0]).name
ARGS = sys.argv[1:]
SYNC_ACTIONS = ("--json", "--flush", "--resume", "--pause", "--terminate", "--status")


def load_world():
    return json.loads(WORLD.read_text())


def save_world(world):
    staging = WORLD.with_suffix(".tmp")
    staging.write_text(json.dumps(world))
    staging.replace(WORLD)


def finish(code, stdout="", stderr=""):
    sys.stdout.write(stdout)
    sys.stderr.write(stderr)
    sys.stdout.flush()
    sys.exit(code)


def remote_kind(command):
    if "git diff" in command:
        return "tree-check"
    if "test@posthog.com" in command:
        return "user-check"
    if "demo-data" in command:
        return "demo-data"
    if re.search(r"hogli up\b", command):
        return "stack-up"
    return "other"


def remote_command(skip):
    if "--" in ARGS:
        return " ".join(ARGS[ARGS.index("--") + 1:])
    return " ".join(ARGS[skip:])


def call_key():
    first = ARGS[0] if ARGS else ""
    if TOOL == "npx":
        return "npx"
    if TOOL == "coder":
        if first == "ssh":
            return "remote:" + remote_kind(remote_command(2))
        return "coder " + first
    if first == "devbox:exec":
        return "remote:" + remote_kind(remote_command(1))
    if first == "devbox:sync":
        actions = [flag for flag in SYNC_ACTIONS if flag in ARGS]
        return "hogli devbox:sync " + (actions[0] if actions else "")
    return "hogli " + first


def log(key):
    if os.environ.get("DEVBOX_FAKE_SETUP"):
        return
    entry = {"tool": TOOL, "argv": ARGS, "cwd": os.getcwd(), "key": key, "pid": os.getpid()}
    with open(ROOT / "calls.jsonl", "a") as handle:
        handle.write(json.dumps(entry) + "\n")


def labeled_box(world):
    if "-n" in ARGS:
        return "devbox-%s-%s" % (world["user"], ARGS[ARGS.index("-n") + 1])
    return "devbox-" + world["user"]


def running(world, name):
    box = world["workspaces"].get(name)
    return bool(box) and box["status"] == "running"


def workspace_json(world, name, box):
    up = box["status"] == "running"
    healthy = up and name == world["label_box"] and world["stack_running"]
    apps = [
        {"slug": "code-server", "display_name": "VS Code", "health": "healthy"},
        {
            "slug": "app",
            "display_name": "PostHog",
            "health": "healthy" if healthy else "unhealthy",
            "healthcheck": {"url": "http://localhost:8010/_health", "interval": 10, "threshold": 12},
        },
    ]
    agents = [{"name": "main", "status": "connected", "lifecycle_state": "ready", "apps": apps}] if up else []
    return {
        "id": box["id"],
        "name": name,
        "owner_name": box["owner"],
        "template_name": "posthog-linux",
        "latest_build": {
            "status": box["status"],
            "transition": "start" if up else "stop",
            "resources": [{"name": "workspace", "type": "aws_instance", "agents": agents}],
        },
    }


def coder_list(world):
    if world["stack_started"] and world["health_after_up"] and not world["stack_running"]:
        world["polls_since_up"] += 1
        if world["polls_since_up"] > world["polls_before_healthy"]:
            world["stack_running"] = True
        save_world(world)
    finish(0, json.dumps([workspace_json(world, n, b) for n, b in world["workspaces"].items()]) + "\n")


def port_forward(world):
    workspace = ARGS[1] if len(ARGS) > 1 else ""
    if "--tcp" in ARGS:
        spec = ARGS[ARGS.index("--tcp") + 1]
    else:
        spec = next(arg for arg in ARGS if arg.startswith("--tcp="))[len("--tcp="):]
    local = int(spec.split(":")[0])
    if not running(world, workspace):
        finish(1, stderr="workspace %s is not running\n" % workspace)
    with open(ROOT / "forwards.jsonl", "a") as handle:
        handle.write(json.dumps({"pid": os.getpid(), "port": local, "workspace": workspace}) + "\n")
    from http.server import BaseHTTPRequestHandler, HTTPServer

    class Health(BaseHTTPRequestHandler):
        def do_GET(self):
            ok = self.path == "/_health"
            body = b"ok" if ok else b"not found"
            self.send_response(200 if ok else 404)
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def log_message(self, *args):
            pass

    HTTPServer(("127.0.0.1", local), Health).serve_forever()


def remote(world, box, kind):
    if not running(world, box):
        finish(1, stderr="workspace %s is not running\n" % box)
    if box != world["label_box"]:
        finish(0)
    if kind == "tree-check":
        if world.get("box_home"):
            # The fake runs the remote script in a real Git checkout under box_home.
            command = ARGS[ARGS.index("--") + 1:]
            result = subprocess.run(command, env=dict(os.environ, HOME=world["box_home"]), capture_output=True, text=True)
            finish(result.returncode, result.stdout, result.stderr)
        if world["box_tree_matches"]:
            finish(0, "DEVBOX_TREE_MATCHES_HEAD\n")
        finish(1, "DEVBOX_TREE_DIFFERS_FROM_HEAD\n")
    if kind == "user-check":
        finish(0, "Python 3.12 shell banner\nDEVBOX_TEST_USER_EXISTS=%s\n" % world["demo_user"])
    if kind == "demo-data":
        world["demo_user"] = True
    elif kind == "stack-up":
        world["stack_started"] = True
        world["polls_since_up"] = 0
    save_world(world)
    finish(0)


def sync(world, box, key):
    state = world["sync"]
    action = key.split(" ")[-1]
    if "--json" in ARGS and any(flag in ARGS for flag in ("--flush", "--resume", "--pause", "--terminate")):
        finish(2, stderr="Error: --json reports state only\n")
    present = state["exists"] and box == world["label_box"]
    if action == "--json":
        sessions = []
        if present:
            sessions.append({
                "name": "devbox-sync-" + box,
                "state": "paused" if state["paused"] else "watching",
                "paused": state["paused"],
                "conflicts": state["conflicts"],
                "conflictPaths": ["frontend/src/scenes/conflicted.tsx"] if state["conflicts"] else [],
                "lastError": None,
                "alpha": world["repo"],
                "beta": "/home/coder/posthog",
            })
        finish(0, json.dumps(sessions) + "\n")
    if not present:
        # hogli's `_label_op` treats a missing session as a silent success.
        finish(0)
    if action == "--resume":
        state["paused"] = state["stays_paused"]
    elif action == "--flush" and state["paused"]:
        finish(1, stderr="session is paused\n")
    elif action == "--pause":
        state["paused"] = True
    save_world(world)
    finish(0)


def hogli(world, key):
    first = ARGS[0] if ARGS else ""
    if first == "--help":
        finish(0, "Usage: hogli [OPTIONS] COMMAND [ARGS]...\n")
    box = labeled_box(world)
    if first == "devbox:start":
        if box not in world["workspaces"]:
            finish(1, stderr="the fake hogli does not create boxes\n")
        world["workspaces"][box]["status"] = "running"
    elif first == "devbox:stop":
        if box in world["workspaces"]:
            world["workspaces"][box]["status"] = "stopped"
        if box == world["label_box"]:
            world["stack_running"] = False
            world["stack_started"] = False
            world["sync"]["paused"] = True
    elif first == "devbox:sync":
        sync(world, box, key)
    save_world(world)
    finish(0)


key = call_key()
log(key)
world = load_world()
behavior = world["behaviors"].get(key, {})
if behavior.get("sleep"):
    time.sleep(behavior["sleep"])
if behavior.get("decoy") and not os.environ.get("DEVBOX_FAKE_DECOY"):
    # Another process starts serving /_health on the port after `forward` chose it. This forward then exits.
    decoy_env = dict(os.environ, DEVBOX_FAKE_SETUP="1", DEVBOX_FAKE_DECOY="1")
    subprocess.Popen(
        [sys.executable, sys.argv[0], *ARGS], env=decoy_env, start_new_session=True,
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
    )
    port = int(next(arg for arg in ARGS if arg.startswith("--tcp="))[len("--tcp="):].split(":")[0])
    import socket
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        try:
            socket.create_connection(("127.0.0.1", port), timeout=1).close()
            break
        except OSError:
            time.sleep(0.02)
    finish(1, stderr="error: listen tcp 127.0.0.1:%d: bind: address already in use\n" % port)
if "exit" in behavior:
    finish(behavior["exit"], behavior.get("stdout", ""), behavior.get("stderr", ""))
if key.startswith("remote:"):
    target = ARGS[1] if TOOL == "coder" else labeled_box(world)
    remote(world, target, key.split(":", 1)[1])
if TOOL == "npx":
    finish(0, "10.9.2\n")
if key == "coder whoami":
    finish(0, json.dumps([{"url": "https://coder.dev.posthog.dev", "username": world["whoami_user"], "id": "u-1"}]) + "\n")
if key == "coder list":
    coder_list(world)
if key == "coder port-forward":
    port_forward(world)
if TOOL == "coder":
    finish(97, stderr="the fake coder does not handle %s\n" % " ".join(ARGS))
hogli(world, key)
'''


# An excerpt of hogli's devbox/mutagen_defaults.yml, which hogli seeds into ~/.hogli/mutagen.yml.
MUTAGEN_CONFIG = """sync:
    defaults:
        mode: one-way-safe
        ignore:
            vcs: true
            paths:
                # A worktree's `.git` is a file.
                - '.git'
                - 'node_modules'
                - '**/__pycache__'
                - '*.pyc'
                - 'build'
                - 'frontend/dist'
                - '.vscode'
"""


def workspace_id(name):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, name))


def records_document(entries):
    """Build the hogli_devbox_worktrees.json document from {worktree path: workspace name}.

    This is the one place that knows the records schema. It mirrors WorktreeBoxRecord in
    tools/hogli-commands/hogli_commands/devbox/config.py, which keys each record by worktree path.
    """
    document = {}
    for path, workspace in entries.items():
        document[str(path)] = {
            "workspace": workspace,
            "git_dir": str(Path(os.path.realpath(path)) / ".git"),
            "workspace_id": workspace_id(workspace) if workspace else None,
            "worktree_id": uuid.uuid5(uuid.NAMESPACE_URL, str(path)).hex,
            "provider": "coder",
        }
    return document


def box(name, owner=USER, status="running"):
    return {"id": workspace_id(name), "owner": owner, "status": status}


def default_world(repo):
    return {
        "user": USER,
        "whoami_user": USER,
        "label_box": WORKSPACE,
        "repo": str(repo),
        "workspaces": {MAIN_BOX: box(MAIN_BOX), WORKSPACE: box(WORKSPACE)},
        "stack_running": True,
        "stack_started": False,
        "health_after_up": True,
        "polls_before_healthy": 0,
        "polls_since_up": 0,
        "demo_user": True,
        "sync": {"exists": True, "paused": False, "conflicts": 0, "stays_paused": False},
        "box_tree_matches": True,
        "behaviors": {},
    }


def free_ports(count):
    sockets = []
    try:
        for _ in range(count):
            sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            sock.bind(("127.0.0.1", 0))
            sockets.append(sock)
        return [sock.getsockname()[1] for sock in sockets]
    finally:
        for sock in sockets:
            sock.close()


def listen_on(port):
    sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    sock.bind(("127.0.0.1", port))
    sock.listen()
    return sock


def ipv6_loopback_available():
    try:
        with socket.socket(socket.AF_INET6, socket.SOCK_STREAM) as sock:
            sock.bind(("::1", 0))
        return True
    except OSError:
        return False


class HealthServer(http.server.HTTPServer):
    def __init__(self, host, port):
        self.address_family = socket.AF_INET6 if ":" in host else socket.AF_INET
        super().__init__((host, port), HealthHandler, bind_and_activate=False)
        if self.address_family == socket.AF_INET6:
            # macOS accepts IPv4 on a dual-stack socket. That would hide the ::1 branch of the port check.
            self.socket.setsockopt(socket.IPPROTO_IPV6, socket.IPV6_V6ONLY, 1)
        self.server_bind()
        self.server_activate()


class HealthHandler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200)
        self.send_header("Content-Length", "2")
        self.end_headers()
        self.wfile.write(b"ok")

    def log_message(self, *args):
        pass


def health_status(port):
    try:
        with urllib.request.urlopen(f"http://127.0.0.1:{port}/_health", timeout=2) as response:
            return response.status
    except OSError:
        return None


def port_accepts(port):
    try:
        with socket.create_connection(("127.0.0.1", port), timeout=1):
            return True
    except OSError:
        return False


def pid_running(pid):
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def wait_until(predicate, timeout=5.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(0.05)
    return predicate()


def command_line(pid):
    return subprocess.run(["ps", "-o", "command=", "-p", str(pid)], capture_output=True, text=True).stdout.strip()


def load_module():
    spec = importlib.util.spec_from_file_location("devbox_stack", SCRIPT)
    module = importlib.util.module_from_spec(spec)
    sys.modules["devbox_stack"] = module
    spec.loader.exec_module(module)
    return module


class DevboxStackTestCase(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devbox-stack-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "posthog"
        self.repo.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.shims = self.root / "bin"
        self.shims.mkdir()
        self.calls_file = self.root / "calls.jsonl"
        self.records_path = self.home / ".config/posthog/hogli_devbox_worktrees.json"
        self.mutagen_config = self.home / ".hogli/mutagen.yml"
        self.state_path = self.repo / ".notes/go-test-plan/devbox.json"
        self.label = LABEL
        self.workspace = WORKSPACE
        self.processes = []
        self.addCleanup(self.stop_processes)
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith(("GIT_", "CODER_", "DEVBOX_"))
        }
        self.env.update(
            {
                "HOME": str(self.home),
                "PATH": f"{self.shims}:/usr/bin:/bin",
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
            }
        )
        fake = f"#!{sys.executable}\nROOT_PATH = {str(self.root)!r}\n" + FAKE
        for name in ("coder", "npx"):
            self.write_executable(self.shims / name, fake)
        self.git("init", "-q", "-b", "haacked/feature")
        self.git("config", "user.name", "Fixture")
        self.git("config", "user.email", "fixture@example.com")
        self.git("config", "commit.gpgsign", "false")
        (self.repo / ".git/info/exclude").write_text(".notes/\n")
        (self.repo / "bin").mkdir()
        self.write_executable(self.repo / "bin/hogli", fake)
        (self.repo / "README.md").write_text("fixture\n")
        self.git("add", "bin/hogli", "README.md")
        self.git("commit", "-qm", "Initial fixture")
        self.head = self.git("rev-parse", "HEAD")
        self.port, *self.fallback_ports = free_ports(4)
        self.mutagen_config.parent.mkdir()
        self.mutagen_config.write_text(MUTAGEN_CONFIG)
        self.reset()

    def write_executable(self, path, content):
        path.write_text(content)
        path.chmod(0o755)

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args], env=self.env, check=True, capture_output=True, text=True
        ).stdout.strip()

    def reset(self):
        self.world = default_world(self.repo)
        self.save_world()
        self.write_records({self.repo: WORKSPACE})
        self.state_path.unlink(missing_ok=True)
        self.clear_calls()

    def save_world(self):
        (self.root / "world.json").write_text(json.dumps(self.world))

    def load_world(self):
        return json.loads((self.root / "world.json").read_text())

    def set_behavior(self, key, **behavior):
        self.world["behaviors"][key] = behavior
        self.save_world()

    def add_box(self, name, owner=USER, status="running"):
        self.world["workspaces"][name] = box(name, owner, status)
        self.save_world()

    def stop_labeled_box(self):
        self.world["workspaces"][WORKSPACE]["status"] = "stopped"
        self.world["stack_running"] = False
        self.world["sync"]["paused"] = True
        self.save_world()

    def write_records(self, entries):
        self.records_path.parent.mkdir(parents=True, exist_ok=True)
        self.records_path.write_text(json.dumps(records_document(entries), indent=2) + "\n")

    def edit_record(self, **fields):
        document = json.loads(self.records_path.read_text())
        document[str(self.repo)].update(fields)
        self.records_path.write_text(json.dumps(document))

    def write_state(self, **fields):
        state = {"workspace": WORKSPACE, "label": LABEL, "started_by_step": False, "forward_pid": None, "port": None}
        state.update(fields)
        self.state_path.parent.mkdir(parents=True, exist_ok=True)
        self.state_path.write_text(json.dumps(state))

    def read_state(self):
        return json.loads(self.state_path.read_text())

    def clear_calls(self):
        self.calls_file.write_text("")

    def calls(self, tool=None):
        if not self.calls_file.exists():
            return []
        entries = [json.loads(line) for line in self.calls_file.read_text().splitlines() if line]
        return [entry for entry in entries if tool is None or entry["tool"] == tool]

    def hogli_log(self):
        return [normalize_hogli(call) for call in self.calls("hogli")]

    def devbox_calls(self):
        return [call for call in self.hogli_log() if call and call[0].startswith(("devbox:", "dev:"))]

    def coder_subcommands(self):
        return [call["argv"][0] if call["argv"] else "" for call in self.calls("coder")]

    def remote_calls(self, kind):
        return [call for call in self.calls() if call["key"] == f"remote:{kind}"]

    def overrides(self, extra=None):
        values = {
            "APP_HEALTH_POLL_INTERVAL": 0.05,
            "FORWARD_POLL_INTERVAL": 0.05,
            "FORWARD_PORT": self.port,
            "FORWARD_FALLBACK_PORTS": list(self.fallback_ports),
        }
        values.update(extra or {})
        return values

    def invoke(self, *args, overrides=None, cwd=None, direct=False):
        if direct:
            command = [sys.executable, str(SCRIPT), *args]
        else:
            command = [sys.executable, "-c", BOOTSTRAP, str(SCRIPT), json.dumps(self.overrides(overrides)), *args]
        result = subprocess.run(
            command, cwd=cwd or self.repo, env=self.env, capture_output=True, text=True, timeout=60
        )
        self.assert_calls_stay_in_scope()
        return result

    def up_args(self):
        return ("up", "--sha", self.head)

    def up(self, **kwargs):
        return self.invoke(*self.up_args(), **kwargs)

    def commit_files(self, message, **contents):
        """Write each path to its content, or delete it when the content is None, then commit and move HEAD."""
        for name, content in contents.items():
            path = self.repo / name
            if content is None:
                self.git("rm", "-q", "--", name)
            else:
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(content)
                self.git("add", "-f", "--", name)
        self.git("commit", "-qm", message)
        self.head = self.git("rev-parse", "HEAD")
        return self.head

    def assert_calls_stay_in_scope(self):
        for call in self.calls("hogli"):
            argv = call["argv"]
            subcommand = argv[0] if argv else ""
            self.assertNotIn(subcommand, NEVER_CALLED_HOGLI, argv)
            self.assertNotIn(MAIN_BOX, argv, argv)
            self.assertNotIn(EU_MAIN_BOX, argv, argv)
            cwd = Path(call["cwd"]).resolve()
            self.assertTrue(cwd == self.repo or self.repo in cwd.parents, f"hogli ran outside the worktree: {cwd}")
            if subcommand.startswith("devbox:"):
                self.assertIn("-n", argv, f"a devbox call without -n targets the main box: {argv}")
                self.assertEqual(argv[argv.index("-n") + 1], self.label, argv)
        for call in self.calls("coder"):
            argv = call["argv"]
            subcommand = argv[0] if argv else ""
            self.assertNotIn(subcommand, NEVER_CALLED_CODER, argv)
            self.assertNotIn(MAIN_BOX, argv, argv)
            self.assertNotIn(EU_MAIN_BOX, argv, argv)
            if subcommand in ("ssh", "port-forward"):
                self.assertEqual(argv[1], self.workspace, argv)

    def payload(self, result):
        self.assertIn(result.returncode, (0, 1, 3), result.stderr)
        try:
            value = json.loads(result.stdout)
        except json.JSONDecodeError:
            self.fail(f"stdout is not one JSON object: {result.stdout!r}\nstderr: {result.stderr}")
        self.assertIsInstance(value, dict, result.stdout)
        return value

    def assert_ok(self, result):
        self.assertEqual(result.returncode, 0, result.stderr + result.stdout)
        return self.payload(result)

    def assert_not_run(self, result):
        self.assertEqual(result.returncode, 3, result.stderr + result.stdout)
        payload = self.payload(result)
        for field in ("reason", "unblock"):
            self.assertIsInstance(payload.get(field), str, payload)
            self.assertTrue(payload[field].strip(), payload)
        return payload

    def assert_no_devbox_calls(self):
        self.assertEqual(self.devbox_calls(), [])
        self.assertEqual(set(self.coder_subcommands()) - {"whoami", "list"}, set())

    def assert_stopped_before_the_stack(self):
        allowed = ("devbox:exec", "-n", LABEL, "<tree-check>")
        self.assertEqual(
            {call[0] for call in self.devbox_calls() if call != allowed} - {"devbox:sync"}, set(), self.hogli_log()
        )
        for kind in ("stack-up", "user-check", "demo-data"):
            self.assertEqual(self.remote_calls(kind), [], kind)

    def start_process(self, argv, **kwargs):
        process = subprocess.Popen(
            argv,
            env=dict(self.env, DEVBOX_FAKE_SETUP="1"),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            **kwargs,
        )
        self.processes.append(process)
        return process

    def serve_health(self, host, port):
        """Answer /_health with 200 on host:port, as a local stack would."""
        server = HealthServer(host, port)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        self.addCleanup(server.server_close)
        self.addCleanup(server.shutdown)
        return server

    def start_fake_forward(self, workspace, port):
        process = self.start_process([str(self.shims / "coder"), "port-forward", workspace, f"--tcp={port}:8010"])
        self.assertTrue(wait_until(lambda: health_status(port) == 200), "fake forward did not serve")
        return process

    def stop_processes(self):
        for process in self.processes:
            if process.poll() is None:
                process.kill()
                process.wait()
        pids = set()
        for path in (self.root / "forwards.jsonl", self.calls_file):
            if path.exists():
                pids.update(json.loads(line)["pid"] for line in path.read_text().splitlines() if line)
        for pid in pids:
            if pid_running(pid) and str(self.root) in command_line(pid):
                os.kill(pid, signal.SIGKILL)


def normalize_hogli(call):
    argv = call["argv"]
    if not argv or not argv[0].startswith("devbox:"):
        return tuple(argv)
    rest = list(argv[1:])
    label = None
    if "-n" in rest:
        index = rest.index("-n")
        label = rest[index + 1]
        del rest[index:index + 2]
    if argv[0] == "devbox:exec":
        return (argv[0], "-n", label, "<%s>" % call["key"].split(":", 1)[1])
    return (argv[0], "-n", label, *sorted(rest))


class ContractTests(DevboxStackTestCase):
    def test_each_spec_timeout_is_a_module_constant_with_the_spec_value(self):
        module = load_module()

        for name, expected in SPEC_CONSTANTS.items():
            with self.subTest(constant=name):
                self.assertEqual(getattr(module, name), expected)

    def test_fallback_ports_are_18010_through_18099(self):
        module = load_module()

        self.assertEqual(list(module.FORWARD_FALLBACK_PORTS), list(range(18010, 18100)))

    def test_script_name_is_not_collected_as_a_test(self):
        self.assertFalse(SCRIPT.name.startswith(("test_", "test-")))

    def test_running_the_file_directly_prints_one_json_object(self):
        result = self.invoke("preflight", direct=True)

        self.assertEqual(self.assert_ok(result)["workspace"], WORKSPACE)

    def test_unexpected_error_exits_1_with_one_json_object(self):
        (self.repo / ".notes").mkdir()
        (self.repo / ".notes/go-test-plan").write_text("a file where the state directory belongs\n")

        result = self.up()

        self.assertEqual(result.returncode, 1, result.stderr + result.stdout)
        self.payload(result)


class PreflightTests(DevboxStackTestCase):
    def test_preflight_reports_workspace_label_user_status_and_health(self):
        payload = self.assert_ok(self.invoke("preflight"))

        self.assertEqual(
            {key: payload.get(key) for key in ("workspace", "label", "user", "status", "app_health")},
            {"workspace": WORKSPACE, "label": LABEL, "user": USER, "status": "running", "app_health": "healthy"},
        )

    def test_preflight_reads_health_from_the_app_app(self):
        self.world["stack_running"] = False
        self.save_world()

        payload = self.assert_ok(self.invoke("preflight"))

        self.assertEqual(payload["app_health"], "unhealthy")

    def test_preflight_on_a_stopped_box_reports_stopped(self):
        self.stop_labeled_box()

        payload = self.assert_ok(self.invoke("preflight"))

        self.assertEqual(payload["status"], "stopped")

    def test_preflight_changes_no_box(self):
        self.assert_ok(self.invoke("preflight"))

        self.assertEqual(self.hogli_log(), [("--help",)])
        self.assertEqual(set(self.coder_subcommands()), {"whoami", "list"})

    def test_missing_coder_is_not_run(self):
        (self.shims / "coder").unlink()

        self.assert_not_run(self.invoke("preflight"))

    def test_missing_npx_is_not_run(self):
        (self.shims / "npx").unlink()

        self.assert_not_run(self.invoke("preflight"))
        self.assert_no_devbox_calls()

    def test_missing_bin_hogli_is_not_run(self):
        (self.repo / "bin/hogli").unlink()

        self.assert_not_run(self.invoke("preflight"))

    def test_failing_hogli_help_is_not_run(self):
        self.set_behavior("hogli --help", exit=1, stderr="ModuleNotFoundError: No module named 'hogli'\n")

        self.assert_not_run(self.invoke("preflight"))
        self.assert_no_devbox_calls()

    def test_whoami_failure_is_not_run_with_the_login_unblock(self):
        self.set_behavior("coder whoami", exit=1, stderr="error: You are not logged in.\n")

        payload = self.assert_not_run(self.invoke("preflight"))

        self.assertIn(CODER_LOGIN_UNBLOCK, payload["unblock"])
        self.assert_no_devbox_calls()

    def test_whoami_timeout_is_not_run(self):
        self.set_behavior("coder whoami", sleep=5)
        started = time.monotonic()

        result = self.invoke("preflight", overrides={"WHOAMI_TIMEOUT": 0.5})

        self.assertLess(time.monotonic() - started, 5)
        self.assert_not_run(result)
        self.assert_no_devbox_calls()

    def test_unreadable_whoami_output_is_not_run(self):
        for stdout in ("not json\n", "[]\n", '[{"url": "https://coder.dev.posthog.dev"}]\n'):
            with self.subTest(stdout=stdout):
                self.reset()
                self.set_behavior("coder whoami", exit=0, stdout=stdout)

                self.assert_not_run(self.invoke("preflight"))

    def test_coder_list_failure_is_not_run(self):
        for behavior in ({"exit": 1, "stderr": "error: unauthorized\n"}, {"exit": 0, "stdout": "not json\n"}):
            with self.subTest(behavior=behavior):
                self.reset()
                self.set_behavior("coder list", **behavior)

                self.assert_not_run(self.invoke("preflight"))
                self.assert_no_devbox_calls()


class BoxGuardTests(DevboxStackTestCase):
    """Risk 1: every subcommand that resolves the box refuses when the record does not prove it is this worktree's own labeled box."""

    def assert_guard_refuses(self, cwd=None):
        payloads = []
        for args in (("preflight",), self.up_args()):
            with self.subTest(command=args[0]):
                self.clear_calls()

                payloads.append(self.assert_not_run(self.invoke(*args, cwd=cwd)))

                self.assert_no_devbox_calls()
        return payloads

    def assert_guard_accepts(self, cwd=None):
        payload = self.assert_ok(self.invoke("preflight", cwd=cwd))
        self.assertEqual((payload["workspace"], payload["label"]), (WORKSPACE, LABEL))

    def test_missing_records_file_is_refused_with_the_worktree_unblock(self):
        self.records_path.unlink()

        for payload in self.assert_guard_refuses():
            self.assertIn("devbox:worktree", payload["unblock"])
            self.assertIn(str(self.repo), payload["unblock"])

    def test_records_file_that_is_not_a_record_map_is_refused(self):
        for text in ("{not json", "", "[]", '"devbox-philh-go-test-plan"', json.dumps({str(self.repo): WORKSPACE})):
            with self.subTest(text=text):
                self.records_path.write_text(text)

                self.assert_guard_refuses()

    def test_record_for_a_path_that_shares_a_prefix_is_refused(self):
        sibling = self.root / "posthog-2"
        sibling.mkdir()
        for path in (sibling, self.root / "post", self.root, self.repo / "frontend"):
            with self.subTest(path=path):
                self.write_records({path: WORKSPACE})

                self.assert_guard_refuses()

    def test_record_keyed_by_a_relative_path_is_refused(self):
        # hogli writes absolute keys. A relative key would resolve against whatever directory the helper runs in.
        for key in (".", "posthog", "../posthog"):
            with self.subTest(key=key):
                document = records_document({self.repo: WORKSPACE})
                self.records_path.write_text(json.dumps({key: document[str(self.repo)]}))

                self.assert_guard_refuses()

    def test_exact_record_wins_over_a_record_for_a_prefix_sharing_sibling(self):
        sibling = self.root / "posthog-2"
        sibling.mkdir()
        self.add_box(f"devbox-{USER}-other")
        self.write_records({sibling: f"devbox-{USER}-other", self.repo: WORKSPACE})

        self.assert_guard_accepts()

    def test_record_path_that_is_a_symlink_to_this_worktree_matches(self):
        link = self.root / "posthog-link"
        link.symlink_to(self.repo, target_is_directory=True)
        self.write_records({link: WORKSPACE})

        self.assert_guard_accepts()

    def test_worktree_reached_through_a_symlink_matches_its_real_record_path(self):
        link = self.root / "posthog-link"
        link.symlink_to(self.repo, target_is_directory=True)

        self.assert_guard_accepts(cwd=link)

    def test_two_records_for_this_worktree_naming_different_boxes_are_refused(self):
        link = self.root / "posthog-link"
        link.symlink_to(self.repo, target_is_directory=True)
        self.add_box(f"devbox-{USER}-other")
        self.write_records({self.repo: WORKSPACE, link: f"devbox-{USER}-other"})

        self.assert_guard_refuses()

    def test_empty_label_is_refused(self):
        for workspace in (f"devbox-{USER}-", ""):
            with self.subTest(workspace=workspace):
                self.write_records({self.repo: workspace})

                self.assert_guard_refuses()

    def test_main_box_record_is_refused(self):
        self.write_records({self.repo: MAIN_BOX})

        self.assert_guard_refuses()

    def test_eu_region_records_are_refused(self):
        for workspace in (EU_MAIN_BOX, f"{WORKSPACE}-eu"):
            with self.subTest(workspace=workspace):
                self.add_box(workspace)
                self.write_records({self.repo: workspace})

                self.assert_guard_refuses()

    def test_recorded_box_coder_does_not_list_is_refused_with_the_worktree_unblock(self):
        cases = (
            (f"devbox-{USER}-gone", {}),
            (WORKSPACE, {f"{WORKSPACE}-2": box(f"{WORKSPACE}-2")}),
        )
        for recorded, listed in cases:
            with self.subTest(recorded=recorded):
                self.reset()
                self.world["workspaces"] = {MAIN_BOX: box(MAIN_BOX), **listed}
                self.save_world()
                self.write_records({self.repo: recorded})

                for payload in self.assert_guard_refuses():
                    self.assertIn("devbox:worktree", payload["unblock"])

    def test_box_for_another_coder_user_is_refused(self):
        cases = (
            ("alice", f"devbox-alice-{LABEL}", USER),
            (f"{USER}x", f"devbox-{USER}x-{LABEL}", USER),
            (USER, WORKSPACE, "alice"),
        )
        for owner, recorded, whoami in cases:
            with self.subTest(recorded=recorded, whoami=whoami):
                self.reset()
                self.add_box(recorded, owner=owner)
                self.world["whoami_user"] = whoami
                self.save_world()
                self.write_records({self.repo: recorded})

                self.assert_guard_refuses()

    def test_record_without_the_devbox_prefix_is_refused(self):
        self.add_box(f"posthog-{LABEL}")
        self.write_records({self.repo: f"posthog-{LABEL}"})

        self.assert_guard_refuses()

    def test_box_recreated_under_the_recorded_name_is_refused(self):
        self.world["workspaces"][WORKSPACE]["id"] = workspace_id("a box made later under the same name")
        self.save_world()

        for payload in self.assert_guard_refuses():
            self.assertIn("devbox:worktree", payload["unblock"])

    def test_record_without_a_workspace_id_is_refused(self):
        for value in (None, ""):
            with self.subTest(workspace_id=value):
                self.reset()
                self.edit_record(workspace_id=value)

                self.assert_guard_refuses()

    def test_record_for_another_provider_is_refused(self):
        self.edit_record(provider="hogland")

        self.assert_guard_refuses()

    def test_eu_twin_of_the_labeled_box_is_refused(self):
        # hogli resolves `-n <label>` to the -eu box when the saved region is EU.
        self.add_box(f"{WORKSPACE}-eu")

        self.assert_guard_refuses()


class UpTests(DevboxStackTestCase):
    def test_up_on_a_running_box_does_not_start_it(self):
        self.assert_ok(self.up())

        self.assertNotIn("devbox:start", [call[0] for call in self.devbox_calls()])
        self.assertEqual(
            {key: self.read_state().get(key) for key in ("workspace", "label", "started_by_step")},
            {"workspace": WORKSPACE, "label": LABEL, "started_by_step": False},
        )

    def test_up_starts_a_stopped_box_and_records_that_it_did(self):
        self.stop_labeled_box()

        self.assert_ok(self.up())

        self.assertEqual([call for call in self.devbox_calls() if call[0] == "devbox:start"], [("devbox:start", "-n", LABEL)])
        self.assertIs(self.read_state()["started_by_step"], True)

    def test_up_resumes_and_flushes_the_sync_before_checking_the_tree_and_starting_the_stack(self):
        self.assert_ok(self.up())

        keys = [call["key"] for call in self.calls()]
        order = [
            "hogli devbox:sync --resume",
            "hogli devbox:sync --flush",
            "hogli devbox:sync --json",
            "remote:tree-check",
            "remote:stack-up",
        ]
        positions = [keys.index(key) for key in order]
        self.assertEqual(positions, sorted(positions), keys)

    def test_up_resumes_a_paused_sync(self):
        self.world["sync"]["paused"] = True
        self.save_world()

        self.assert_ok(self.up())

        self.assertFalse(self.load_world()["sync"]["paused"])

    def test_tree_check_runs_on_the_labeled_box_against_head(self):
        self.assert_ok(self.up())

        checks = self.remote_calls("tree-check")
        self.assertEqual(len(checks), 1)
        self.assertEqual(checks[0]["tool"], "hogli")
        self.assertEqual(checks[0]["argv"][:3], ["devbox:exec", "-n", LABEL])
        command = " ".join(checks[0]["argv"])
        self.assertIn("git diff --quiet", command)
        self.assertIn(self.head, command)

    def test_up_brings_the_stack_up_on_the_labeled_box(self):
        self.assert_ok(self.up())

        self.assertEqual(len(self.remote_calls("stack-up")), 1)

    def test_up_waits_until_the_app_turns_healthy(self):
        self.world.update(stack_running=False, polls_before_healthy=3)
        self.save_world()

        self.assert_ok(self.up())

        self.assertTrue(self.load_world()["stack_running"])

    def test_health_wait_that_never_turns_healthy_is_not_run(self):
        self.world.update(stack_running=False, health_after_up=False)
        self.save_world()
        started = time.monotonic()

        result = self.up(overrides={"APP_HEALTH_TIMEOUT": 0.5})

        self.assertLess(time.monotonic() - started, 10)
        self.assert_not_run(result)

    def test_demo_data_runs_once_when_the_test_user_is_missing(self):
        self.world["demo_user"] = False
        self.save_world()

        self.assert_ok(self.up())
        self.assert_ok(self.up())

        self.assertEqual(len(self.remote_calls("demo-data")), 1)

    def test_demo_data_never_runs_when_the_test_user_exists(self):
        self.assert_ok(self.up())

        self.assertEqual(len(self.remote_calls("user-check")), 1)
        self.assertEqual(self.remote_calls("demo-data"), [])

    def test_user_check_that_fails_or_answers_neither_true_nor_false_is_not_run(self):
        for behavior in ({"exit": 1, "stderr": "django.db.utils.OperationalError\n"}, {"exit": 0, "stdout": "maybe\n"}):
            with self.subTest(behavior=behavior):
                self.reset()
                self.world["demo_user"] = False
                self.save_world()
                self.set_behavior("remote:user-check", **behavior)

                self.assert_not_run(self.up())
                self.assertEqual(self.remote_calls("demo-data"), [])

    def test_failing_demo_data_is_not_run(self):
        self.world["demo_user"] = False
        self.set_behavior("remote:demo-data", exit=1)

        self.assert_not_run(self.up())

    def test_failing_box_start_is_not_run(self):
        self.stop_labeled_box()
        self.set_behavior("hogli devbox:start", exit=1, stderr="agent never connected\n")

        self.assert_not_run(self.up())
        self.assertEqual(self.remote_calls("stack-up"), [])

    def test_failing_stack_up_is_not_run(self):
        self.set_behavior("remote:stack-up", exit=1)

        self.assert_not_run(self.up())
        self.assertEqual(self.remote_calls("demo-data"), [])

    def test_stack_up_restarts_the_stack_and_waits_for_its_processes(self):
        self.assert_ok(self.up())

        command = " ".join(self.remote_calls("stack-up")[0]["argv"])
        positions = [command.index(step) for step in ("hogli stop", "hogli up -d -y", "hogli wait --timeout")]
        self.assertEqual(positions, sorted(positions), command)

    def test_box_in_a_pending_state_is_not_started(self):
        self.world["workspaces"][WORKSPACE]["status"] = "starting"
        self.save_world()

        self.assert_not_run(self.up())

        self.assertEqual(self.devbox_calls(), [])
        self.assertIs(self.read_state()["started_by_step"], False)

    def test_start_that_leaves_the_box_stopped_is_not_run(self):
        self.stop_labeled_box()
        self.set_behavior("hogli devbox:start", exit=0)

        self.assert_not_run(self.up())

        self.assertEqual(self.devbox_calls(), [("devbox:start", "-n", LABEL)])
        self.assertIs(self.read_state()["started_by_step"], True)

    def test_up_with_state_for_another_box_is_refused(self):
        self.write_state(workspace=f"devbox-{USER}-other", label="other", started_by_step=True)

        self.assert_not_run(self.up())

        self.assertEqual(self.devbox_calls(), [])
        self.assertEqual(self.read_state()["workspace"], f"devbox-{USER}-other")

    def test_up_keeps_started_by_step_from_an_earlier_up_on_the_same_box(self):
        self.write_state(started_by_step=True)

        payload = self.assert_ok(self.up())

        self.assertIs(payload["started_by_step"], True)
        self.assertIs(self.read_state()["started_by_step"], True)


class TreeParityTests(DevboxStackTestCase):
    """Risk 2: up refuses unless the box's tracked files equal local HEAD and the local tree is clean."""

    def test_dirty_local_tree_is_refused_before_any_devbox_call(self):
        def modify_tracked():
            (self.repo / "README.md").write_text("changed\n")

        def stage_new_file():
            (self.repo / "staged.txt").write_text("staged\n")
            self.git("add", "staged.txt")

        def add_untracked():
            (self.repo / "untracked.txt").write_text("untracked\n")

        for make_dirty in (modify_tracked, stage_new_file, add_untracked):
            with self.subTest(case=make_dirty.__name__):
                self.git("reset", "-q", "--hard")
                self.git("clean", "-fdq")
                self.reset()
                make_dirty()

                self.assert_not_run(self.up())
                self.assertEqual(self.devbox_calls(), [])

    def test_sha_other_than_local_head_is_refused_before_any_devbox_call(self):
        first = self.head
        (self.repo / "second.txt").write_text("second\n")
        self.git("add", "second.txt")
        self.git("commit", "-qm", "Second commit")

        self.assert_not_run(self.invoke("up", "--sha", first))
        self.assertEqual(self.devbox_calls(), [])

    def test_sync_that_stays_paused_is_refused(self):
        self.world["sync"].update(paused=True, stays_paused=True)
        self.save_world()

        self.assert_not_run(self.up())
        self.assert_stopped_before_the_stack()

    def test_sync_paused_according_to_its_json_is_refused(self):
        self.set_behavior(
            "hogli devbox:sync --json",
            exit=0,
            stdout=json.dumps([{"name": "s", "state": "paused", "paused": True, "conflicts": 0, "conflictPaths": []}]),
        )

        self.assert_not_run(self.up())
        self.assert_stopped_before_the_stack()

    def test_sync_conflict_is_refused(self):
        self.world["sync"]["conflicts"] = 2
        self.save_world()

        self.assert_not_run(self.up())
        self.assert_stopped_before_the_stack()

    def test_missing_or_unreadable_sync_state_is_refused(self):
        for stdout in ("[]\n", "not json\n", "{}\n"):
            with self.subTest(stdout=stdout):
                self.reset()
                self.set_behavior("hogli devbox:sync --json", exit=0, stdout=stdout)

                self.assert_not_run(self.up())
                self.assert_stopped_before_the_stack()

    def test_failing_sync_flush_is_refused(self):
        self.set_behavior("hogli devbox:sync --flush", exit=1, stderr="mutagen: session halted\n")

        self.assert_not_run(self.up())
        self.assert_stopped_before_the_stack()

    def test_box_tree_that_differs_from_head_is_refused(self):
        self.world["box_tree_matches"] = False
        self.save_world()

        payload = self.assert_not_run(self.up())

        self.assertIn("does not match HEAD", payload["reason"])
        self.assert_stopped_before_the_stack()

    def test_tree_check_that_cannot_run_is_refused(self):
        cases = (
            {"exit": 128, "stderr": "fatal: remote error: upload-pack: not our ref\n"},
            {"exit": 255, "stderr": "ssh: connect to host failed\n"},
            # hogli's `_fail` prints its message on stdout and exits 1. `git diff --quiet` uses the same exit code for a difference.
            {"exit": 1, "stdout": "SSH access for devboxes isn't configured. Run `hogli devbox:setup` (it runs `coder config-ssh`), then retry.\n"},
        )
        for behavior in cases:
            with self.subTest(exit=behavior["exit"]):
                self.reset()
                self.set_behavior("remote:tree-check", **behavior)

                payload = self.assert_not_run(self.up())

                self.assertNotIn("does not match HEAD", payload["reason"])
                self.assertIn("could not compare", payload["reason"])
                self.assert_stopped_before_the_stack()

    def test_box_that_cannot_fetch_head_is_refused_with_the_push_unblock(self):
        # The tree check exits 10 when `git fetch origin <sha>` fails, which happens when the branch is not pushed.
        self.set_behavior("remote:tree-check", exit=10, stderr="fatal: remote error: upload-pack: not our ref\n")

        payload = self.assert_not_run(self.up())

        self.assertIn("push the branch", payload["unblock"])
        self.assert_stopped_before_the_stack()

    def test_tree_check_that_exits_0_without_confirming_the_match_is_refused(self):
        self.set_behavior("remote:tree-check", exit=0, stdout="")

        self.assert_not_run(self.up())
        self.assert_stopped_before_the_stack()

    def test_tree_check_reads_head_into_a_fresh_index(self):
        # The box's own index stays at the first sync's commit. `git diff <sha>` against it reports every file added since as deleted.
        self.assert_ok(self.up())

        command = " ".join(self.remote_calls("tree-check")[0]["argv"])
        self.assertIn(f'GIT_INDEX_FILE="$index" git read-tree {self.head}', command)
        self.assertIn(f'GIT_INDEX_FILE="$index" git diff --quiet {self.head}', command)

    def test_tracked_files_the_sync_ignores_are_reported_and_excluded_from_the_tree_check(self):
        ignored = [".vscode/launch.json", "frontend/dist/app.js", "products/x/build/icon.png", "rust/__pycache__/m.pyc"]
        names = (*ignored, "frontend/src/build.tsx", "frontend/distribution.ts")
        self.commit_files("Add files the sync ignores", **{name: "tracked\n" for name in names})
        self.commit_files("Change mirrored files on the branch", **{"frontend/src/build.tsx": "changed\n", "README.md": "changed\n"})

        payload = self.assert_ok(self.up())

        self.assertEqual(payload["unmirrored_paths"], sorted(ignored))
        argv = self.remote_calls("tree-check")[0]["argv"]
        command = " ".join(argv)
        for name in ignored:
            self.assertIn(f"':(exclude,literal){name}'", command)
        self.assertNotIn("frontend/src/build.tsx", command)

    def test_ignore_list_the_helper_cannot_read_is_refused_before_any_devbox_call(self):
        cases = {
            "missing": None,
            "flow list": "sync:\n  defaults:\n    ignore:\n      paths: ['build']\n",
            "negation": "sync:\n  defaults:\n    ignore:\n      paths:\n        - '!keep'\n",
            "mapping item": "sync:\n  defaults:\n    ignore:\n      paths:\n        build: true\n",
        }
        for case, text in cases.items():
            with self.subTest(case=case):
                self.reset()
                self.mutagen_config.unlink(missing_ok=True)
                if text is not None:
                    self.mutagen_config.write_text(text)

                self.assert_not_run(self.up())
                self.assertEqual(self.devbox_calls(), [])

    def test_sync_that_mirrors_another_checkout_is_refused(self):
        for alpha in (str(self.root / "posthog-2"), ".", None):
            with self.subTest(alpha=alpha):
                self.reset()
                session = {"name": "s", "state": "watching", "paused": False, "conflicts": 0, "conflictPaths": [], "alpha": alpha}
                self.set_behavior("hogli devbox:sync --json", exit=0, stdout=json.dumps([session]))

                self.assert_not_run(self.up())
                self.assert_stopped_before_the_stack()

    def test_refusal_after_starting_the_box_leaves_state_that_lets_down_stop_it(self):
        self.stop_labeled_box()
        self.world["box_tree_matches"] = False
        self.save_world()

        self.assert_not_run(self.up())
        self.assertIs(self.read_state()["started_by_step"], True)
        self.clear_calls()
        self.assert_ok(self.invoke("down"))

        self.assertEqual(self.devbox_calls(), [("devbox:stop", "-n", LABEL)])


class BoxCheckoutTests(DevboxStackTestCase):
    """The box's copies of unmirrored paths come from the commit of its first sync, so `up` compares that commit with HEAD."""

    def make_box(self, commit, unmirrored=(), kept=()):
        """Check out commit on a fake box, cloning it on first use, then mirror local HEAD's tracked files except the unmirrored ones.

        A file of commit that local HEAD lacks is removed from the box unless it is in kept, which stands for a file
        that mutagen's one-way-safe mode leaves on the box.
        """
        self.box_home = self.root / "box-home"
        self.box = self.box_home / "posthog"
        if not self.box.exists():
            subprocess.run(["git", "clone", "-q", str(self.repo), str(self.box)], env=self.env, check=True)
        self.box_git("checkout", "-q", "--detach", commit)
        local = {name for name in self.git("ls-files", "-z").split("\0") if name}
        for name in self.box_git("ls-files", "-z").split("\0"):
            if name and name not in local and name not in unmirrored and name not in kept:
                (self.box / name).unlink()
        for name in local - set(unmirrored):
            target = self.box / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes((self.repo / name).read_bytes())
            target.chmod((self.repo / name).stat().st_mode)
        self.world["box_home"] = str(self.box_home)
        self.save_world()

    def box_git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.box), *args], env=self.env, check=True, capture_output=True, text=True
        ).stdout

    def test_unmirrored_files_that_main_changed_after_the_first_sync_are_refused_before_the_stack(self):
        stale = {
            ".vscode/launch.json": "added\n",
            "frontend/dist/app.js": "new\n",
            "frontend/dist/my chunk.js": "new\n",
            "products/x/build/gone.js": None,
            "frontend/dist/renamed.js": "moved\n",
            "frontend/dist/before-rename.js": None,
        }
        first_sync = self.commit_files(
            "Main at the first sync",
            **{
                "frontend/dist/app.js": "old\n",
                "frontend/dist/my chunk.js": "old\n",
                "products/x/build/gone.js": "old\n",
                "frontend/dist/before-rename.js": "moved\n",
            },
        )
        self.make_box(first_sync)
        self.commit_files("Main changes unmirrored files", **stale)
        self.commit_files("Branch change", **{"frontend/src/a.tsx": "branch\n"})
        self.make_box(first_sync, unmirrored=tuple(stale))

        payload = self.assert_not_run(self.up())

        for name in stale:
            self.assertIn(name, payload["reason"])
            self.assertIn(name, payload["unblock"])
        self.assertIn("first sync", payload["reason"])
        self.assertNotIn("frontend/src/a.tsx", payload["reason"])
        self.assertNotIn("does not match HEAD", payload["reason"])
        self.assertNotIn("deletes", payload["reason"])
        self.assertNotIn("rm -f", payload["unblock"])
        self.assert_stopped_before_the_stack()

        self.run_unblock(payload)
        self.assertEqual(self.box_git("rev-parse", "HEAD").strip(), self.head)
        self.assertFalse((self.box / "products/x/build/gone.js").exists())
        self.assertFalse((self.box / "frontend/dist/before-rename.js").exists())
        self.assertEqual((self.box / "frontend/dist/app.js").read_text(), "new\n")
        self.assertEqual((self.box / "frontend/dist/my chunk.js").read_text(), "new\n")
        self.clear_calls()

        self.assert_ok(self.up())

    def test_branch_change_to_an_unmirrored_file_is_refused_and_repaired_on_the_box(self):
        def add():
            self.commit_files("Add an ignored file", **{"frontend/dist/app.js": "new\n"})
            return root, ["frontend/dist/app.js"]

        def modify():
            first_sync = self.commit_files("Base", **{".vscode/launch.json": "old\n"})
            self.commit_files("Modify an ignored file", **{".vscode/launch.json": "new\n"})
            return first_sync, [".vscode/launch.json"]

        def delete():
            first_sync = self.commit_files("Base", **{"products/x/build/icon.png": "old\n"})
            self.commit_files("Delete an ignored file", **{"products/x/build/icon.png": None})
            return first_sync, ["products/x/build/icon.png"]

        def rename_out():
            first_sync = self.commit_files("Base", **{"frontend/dist/app.js": "same\n"})
            (self.repo / "frontend/src").mkdir(parents=True, exist_ok=True)
            self.git("mv", "frontend/dist/app.js", "frontend/src/app.js")
            self.commit_files("Move a file out of an ignored directory")
            return first_sync, ["frontend/dist/app.js"]

        def rename_within():
            first_sync = self.commit_files("Base", **{"frontend/dist/a.js": "same\n"})
            self.git("mv", "frontend/dist/a.js", "frontend/dist/b.js")
            self.commit_files("Rename a file inside an ignored directory")
            return first_sync, ["frontend/dist/a.js", "frontend/dist/b.js"]

        def nested_name():
            self.commit_files("Add a nested ignored name", **{"rust/__pycache__/m.pyc": "new\n", "rust/src/lib.rs": "new\n"})
            return root, ["rust/__pycache__/m.pyc"]

        root = self.head
        for change in (add, modify, delete, rename_out, rename_within, nested_name):
            with self.subTest(case=change.__name__):
                self.git("reset", "-q", "--hard", root)
                self.git("clean", "-fdq")
                self.head = root
                self.reset()
                shutil.rmtree(self.root / "box-home", ignore_errors=True)
                first_sync, expected = change()
                self.make_box(first_sync, unmirrored=tuple(expected))

                payload = self.assert_not_run(self.up())

                for name in expected:
                    self.assertIn(name, payload["reason"])
                    self.assertIn(name, payload["unblock"])
                self.assertIn("first sync", payload["reason"])
                self.assertNotIn("frontend/src/app.js", payload["reason"])
                self.assertNotIn("rust/src/lib.rs", payload["reason"])
                self.assert_stopped_before_the_stack()

                self.run_unblock(payload)
                self.assertEqual(self.box_git("rev-parse", "HEAD").strip(), self.head)
                self.assertEqual(self.box_git("status", "--porcelain", "--untracked-files=all"), "")
                self.clear_calls()

                self.assert_ok(self.up())

    def test_unmirrored_file_whose_name_holds_a_newline_is_refused_as_a_failed_comparison(self):
        name = "frontend/dist/a\nb.js"
        first_sync = self.head
        self.commit_files("Add an ignored file whose name holds a newline", **{name: "new\n"})
        self.make_box(first_sync, unmirrored=(name,))

        payload = self.assert_not_run(self.up())

        self.assertIn("could not compare", payload["reason"])
        self.assert_stopped_before_the_stack()

    def test_unmirrored_files_equal_in_the_box_commit_and_head_pass(self):
        cases = {
            "tracked unmirrored file": {"frontend/dist/app.js": "same\n"},
            "no tracked unmirrored file": {},
        }
        root = self.head
        for case, unmirrored in cases.items():
            for ignore_list in (MUTAGEN_CONFIG, "sync:\n  defaults:\n    ignore:\n      paths:\n"):
                with self.subTest(case=case, ignore_list=ignore_list):
                    self.git("reset", "-q", "--hard", root)
                    self.reset()
                    shutil.rmtree(self.root / "box-home", ignore_errors=True)
                    self.mutagen_config.write_text(ignore_list)
                    first_sync = self.commit_files("Main at the first sync", **unmirrored, **{"posthog/a.py": "old\n"})
                    self.commit_files("Newer main", **{"posthog/a.py": "new\n", "README.md": "newer\n"})
                    self.commit_files("Branch change", **{"frontend/src/a.tsx": "branch\n"})
                    self.make_box(first_sync, unmirrored=tuple(unmirrored))

                    self.assert_ok(self.up())
                    self.assertEqual(len(self.remote_calls("stack-up")), 1)

    def test_box_build_that_rewrites_an_unmirrored_file_at_head_passes(self):
        self.commit_files("Add a build output", **{"frontend/dist/app.js": "committed\n"})
        self.make_box(self.head, unmirrored=("frontend/dist/app.js",))
        (self.box / "frontend/dist/app.js").write_text("built on the box\n")
        (self.box / "frontend/dist/chunk.js").write_text("untracked build output\n")

        payload = self.assert_ok(self.up())

        self.assertEqual(payload["unmirrored_paths"], ["frontend/dist/app.js"])

    def test_stale_sentinel_without_its_exit_code_or_paths_is_refused_as_a_failed_comparison(self):
        cases = (
            {"exit": 11, "stdout": ""},
            {"exit": 11, "stdout": "DEVBOX_UNMIRRORED_DIFFERS_FROM_HEAD\n"},
            {"exit": 11, "stdout": "DEVBOX_BOX_KEEPS_FILES_HEAD_DELETES\n"},
            {"exit": 11, "stdout": "DEVBOX_UNMIRRORED_DIFFERS_FROM_HEAD\nDEVBOX_BOX_KEEPS_FILES_HEAD_DELETES\n"},
            {"exit": 1, "stdout": "DEVBOX_BOX_KEEPS_FILES_HEAD_DELETES\nposthog/a.py\n"},
            {"exit": 1, "stdout": "DEVBOX_UNMIRRORED_DIFFERS_FROM_HEAD\nfrontend/dist/app.js\n"},
        )
        for behavior in cases:
            with self.subTest(**behavior):
                self.reset()
                self.set_behavior("remote:tree-check", **behavior)

                payload = self.assert_not_run(self.up())

                self.assertIn("could not compare", payload["reason"])
                self.assert_stopped_before_the_stack()

    def run_unblock(self, payload):
        command = shlex.split(payload["unblock"].split("`")[1])
        self.assertEqual(command[:7], ["bin/hogli", "devbox:exec", "-n", LABEL, "--", "bash", "-c"])
        subprocess.run(command[5:], env=dict(self.env, HOME=str(self.box_home)), check=True)

    def test_files_head_deletes_that_the_box_kept_are_refused_before_the_stack(self):
        kept = ("posthog/migrations/0999_gone.py", "posthog/api/old module.py", "-leading-dash.py")
        first_sync = self.commit_files("Main at the first sync", **{name: "old\n" for name in kept})
        self.commit_files("Main deletes files", **{name: None for name in kept})
        self.commit_files("Branch change", **{"frontend/src/a.tsx": "branch\n"})
        self.make_box(first_sync, kept=kept)
        (self.box / "posthog/celerybeat-schedule").write_text("runtime file\n")

        payload = self.assert_not_run(self.up())

        for name in kept:
            self.assertIn(name, payload["reason"])
            self.assertIn(name, payload["unblock"])
        self.assertIn("deletes", payload["reason"])
        self.assertNotIn("celerybeat-schedule", payload["reason"])
        self.assertNotIn("does not match HEAD", payload["reason"])
        self.assert_stopped_before_the_stack()

        self.run_unblock(payload)
        self.assertEqual(self.box_git("rev-parse", "HEAD").strip(), self.head)
        for name in kept:
            self.assertFalse((self.box / name).exists(), name)
        self.assertTrue((self.box / "posthog/celerybeat-schedule").exists())
        self.clear_calls()

        self.assert_ok(self.up())

    def test_kept_files_and_stale_unmirrored_files_are_refused_and_repaired_together(self):
        first_sync = self.commit_files(
            "Main at the first sync", **{"frontend/dist/app.js": "old\n", "posthog/models/gone.py": "old\n"}
        )
        self.commit_files(
            "Main changes both", **{"frontend/dist/app.js": "new\n", "posthog/models/gone.py": None}
        )
        self.commit_files("Branch change", **{"frontend/src/a.tsx": "branch\n"})
        self.make_box(first_sync, unmirrored=("frontend/dist/app.js",), kept=("posthog/models/gone.py",))

        payload = self.assert_not_run(self.up())

        for name in ("frontend/dist/app.js", "posthog/models/gone.py"):
            self.assertIn(name, payload["reason"])
            self.assertIn(name, payload["unblock"])
        self.assertIn("first sync", payload["reason"])
        self.assertIn("deletes", payload["reason"])

        self.run_unblock(payload)
        self.assertEqual((self.box / "frontend/dist/app.js").read_text(), "new\n")
        self.assertFalse((self.box / "posthog/models/gone.py").exists())
        self.clear_calls()

        self.assert_ok(self.up())

    def test_kept_dangling_symlink_that_head_deletes_is_refused(self):
        link = "posthog/settings/old-link"
        (self.repo / link).parent.mkdir(parents=True)
        os.symlink("missing-target", self.repo / link)
        self.git("add", "--", link)
        first_sync = self.commit_files("Main at the first sync")
        self.commit_files("Main deletes the link", **{link: None})
        self.make_box(first_sync, kept=(link,))

        payload = self.assert_not_run(self.up())

        self.assertIn(link, payload["reason"])
        self.run_unblock(payload)
        self.assertFalse(os.path.lexists(self.box / link))

    def test_kept_file_whose_name_holds_a_newline_is_refused_as_a_failed_comparison(self):
        kept = ("posthog/a\nb.py",)
        first_sync = self.commit_files("Main at the first sync", **{kept[0]: "old\n", "posthog/a": "mirrored\n"})
        self.commit_files("Main deletes the file", **{kept[0]: None})
        self.make_box(first_sync, kept=kept)

        payload = self.assert_not_run(self.up())

        self.assertIn("could not compare", payload["reason"])
        self.assert_stopped_before_the_stack()

    def test_files_head_deletes_that_are_gone_from_the_box_pass(self):
        first_sync = self.commit_files(
            "Main at the first sync", **{"posthog/migrations/0999_gone.py": "old\n", "posthog/x": "a file\n"}
        )
        self.commit_files(
            "Main deletes a file and turns another into a directory",
            **{"posthog/migrations/0999_gone.py": None, "posthog/x": None},
        )
        self.commit_files("Main adds the directory", **{"posthog/x/__init__.py": "package\n"})
        self.commit_files("Branch change", **{"frontend/src/a.tsx": "branch\n"})
        self.make_box(first_sync)

        self.assert_ok(self.up())

        self.assertEqual(len(self.remote_calls("stack-up")), 1)

    def test_mirrored_file_that_differs_on_the_box_is_refused_as_a_tree_mismatch(self):
        first_sync = self.head
        self.commit_files("Branch change", **{"frontend/src/a.tsx": "branch\n"})
        self.make_box(first_sync)
        (self.box / "frontend/src/a.tsx").write_text("lagging sync\n")

        payload = self.assert_not_run(self.up())

        self.assertIn("does not match HEAD", payload["reason"])
        self.assert_stopped_before_the_stack()


class TimeoutTests(DevboxStackTestCase):
    """Risk 4: a call that hangs past its timeout ends not-run instead of stalling the run."""

    def test_each_hung_call_ends_not_run_within_its_timeout(self):
        def running_box():
            pass

        def stopped_box():
            self.stop_labeled_box()

        def missing_user():
            self.world["demo_user"] = False
            self.save_world()

        def box_the_step_started():
            self.write_state(started_by_step=True)

        cases = (
            ("coder whoami", "WHOAMI_TIMEOUT", ("preflight",), running_box),
            ("coder list", "LIST_TIMEOUT", ("preflight",), running_box),
            ("hogli --help", "HOGLI_HELP_TIMEOUT", ("preflight",), running_box),
            ("hogli devbox:start", "START_TIMEOUT", self.up_args(), stopped_box),
            ("hogli devbox:sync --flush", "SYNC_FLUSH_TIMEOUT", self.up_args(), running_box),
            ("remote:tree-check", "TREE_CHECK_TIMEOUT", self.up_args(), running_box),
            ("remote:stack-up", "STACK_UP_TIMEOUT", self.up_args(), running_box),
            ("remote:user-check", "USER_CHECK_TIMEOUT", self.up_args(), running_box),
            ("remote:demo-data", "DEMO_DATA_TIMEOUT", self.up_args(), missing_user),
            ("hogli devbox:stop", "STOP_TIMEOUT", ("down",), box_the_step_started),
        )
        for key, constant, args, arrange in cases:
            with self.subTest(call=key):
                self.reset()
                arrange()
                self.set_behavior(key, sleep=5)
                started = time.monotonic()

                result = self.invoke(*args, overrides={constant: 0.5})

                self.assertLess(time.monotonic() - started, 5)
                self.assert_not_run(result)


class ForwardTests(DevboxStackTestCase):
    def setUp(self):
        super().setUp()
        self.write_state()

    def test_forward_serves_the_app_on_the_preferred_port(self):
        payload = self.assert_ok(self.invoke("forward"))

        self.assertEqual(payload["url"], f"http://localhost:{self.port}")
        self.assertEqual(health_status(self.port), 200)

    def test_forward_maps_the_local_port_to_8010_on_the_labeled_box(self):
        self.assert_ok(self.invoke("forward"))

        forwards = [call["argv"] for call in self.calls("coder") if call["key"] == "coder port-forward"]
        self.assertEqual(forwards, [["port-forward", WORKSPACE, "--disable-autostart", f"--tcp={self.port}:8010"]])

    def test_forward_records_its_pid_and_port(self):
        self.assert_ok(self.invoke("forward"))

        state = self.read_state()
        self.assertEqual(state["port"], self.port)
        self.assertIn("port-forward", command_line(state["forward_pid"]))
        self.assertTrue((self.repo / ".notes/go-test-plan/forward.log").exists())

    def test_forward_uses_the_first_free_fallback_port_when_the_preferred_port_is_busy(self):
        busy = listen_on(self.port)
        self.addCleanup(busy.close)

        payload = self.assert_ok(self.invoke("forward"))

        self.assertEqual(payload["url"], f"http://localhost:{self.fallback_ports[0]}")
        self.assertEqual(health_status(self.fallback_ports[0]), 200)

    def assert_forward_skips_a_local_server_on(self, host):
        self.serve_health(host, self.port)

        payload = self.assert_ok(self.invoke("forward"))

        self.assertEqual(payload["url"], f"http://localhost:{self.fallback_ports[0]}")

    def test_forward_skips_a_preferred_port_that_a_local_server_holds_on_the_ipv4_wildcard(self):
        self.assert_forward_skips_a_local_server_on("0.0.0.0")

    @unittest.skipUnless(ipv6_loopback_available(), "the host has no IPv6 loopback")
    def test_forward_skips_a_preferred_port_that_a_local_server_holds_on_the_ipv6_wildcard(self):
        self.assert_forward_skips_a_local_server_on("::")

    def test_forward_whose_process_exits_while_another_server_answers_health_is_not_run(self):
        self.set_behavior("coder port-forward", decoy=True)

        payload = self.assert_not_run(self.invoke("forward", overrides={"FORWARD_POLL_INTERVAL": 0.2}))

        self.assertIn(str(self.port), payload["unblock"])
        self.assertIsNone(self.read_state()["forward_pid"])
        self.assertEqual(health_status(self.port), 200)

    def test_forward_skips_busy_fallback_ports(self):
        for port in (self.port, self.fallback_ports[0]):
            busy = listen_on(port)
            self.addCleanup(busy.close)

        payload = self.assert_ok(self.invoke("forward"))

        self.assertEqual(payload["url"], f"http://localhost:{self.fallback_ports[1]}")

    def test_forward_with_no_free_port_is_not_run(self):
        for port in (self.port, *self.fallback_ports):
            busy = listen_on(port)
            self.addCleanup(busy.close)

        self.assert_not_run(self.invoke("forward"))
        self.assertNotIn("port-forward", self.coder_subcommands())

    def test_forward_kills_a_stale_forward_before_choosing_a_port(self):
        stale = self.start_fake_forward(WORKSPACE, self.port)
        self.write_state(forward_pid=stale.pid, port=self.port)

        payload = self.assert_ok(self.invoke("forward"))

        stale.wait(timeout=5)
        self.assertEqual(payload["url"], f"http://localhost:{self.port}")
        self.assertNotEqual(self.read_state()["forward_pid"], stale.pid)
        self.assertEqual(health_status(self.port), 200)

    def test_forward_that_never_serves_is_not_run_and_leaves_no_process(self):
        self.set_behavior("coder port-forward", sleep=30, exit=1)
        started = time.monotonic()

        result = self.invoke("forward", overrides={"FORWARD_HEALTH_TIMEOUT": 1})

        self.assertLess(time.monotonic() - started, 15)
        self.assert_not_run(result)
        pids = [call["pid"] for call in self.calls("coder") if call["key"] == "coder port-forward"]
        self.assertTrue(pids)
        self.assertTrue(wait_until(lambda: not any(pid_running(pid) for pid in pids)), "the hung forward survived")

    def test_forward_without_state_is_not_run(self):
        self.state_path.unlink()

        self.assert_not_run(self.invoke("forward"))
        self.assertNotIn("port-forward", self.coder_subcommands())

    def test_forward_with_state_for_another_box_is_not_run(self):
        for workspace, label in ((MAIN_BOX, ""), (f"devbox-{USER}-other", "other")):
            with self.subTest(workspace=workspace):
                self.add_box(workspace)
                self.write_state(workspace=workspace, label=label)

                self.assert_not_run(self.invoke("forward"))
                self.assertNotIn("port-forward", self.coder_subcommands())

    def test_forward_that_exits_at_once_is_not_run(self):
        self.set_behavior("coder port-forward", exit=1, stderr="error: workspace agent is not connected\n")

        self.assert_not_run(self.invoke("forward", overrides={"FORWARD_HEALTH_TIMEOUT": 1}))


class DownTests(DevboxStackTestCase):
    def test_down_kills_the_forward_and_removes_the_state(self):
        self.write_state()
        self.assert_ok(self.invoke("forward"))
        pid = self.read_state()["forward_pid"]

        self.assert_ok(self.invoke("down"))

        self.assertTrue(wait_until(lambda: not pid_running(pid)), "the forward survived down")
        self.assertFalse(port_accepts(self.port))
        self.assertFalse(self.state_path.exists())

    def test_down_stops_a_box_the_step_started(self):
        self.write_state(started_by_step=True)

        self.assert_ok(self.invoke("down"))

        self.assertEqual(self.devbox_calls(), [("devbox:stop", "-n", LABEL)])
        self.assertEqual(self.load_world()["workspaces"][WORKSPACE]["status"], "stopped")

    def test_down_leaves_running_a_box_the_step_did_not_start(self):
        self.write_state(started_by_step=False)

        self.assert_ok(self.invoke("down"))

        self.assertEqual(self.devbox_calls(), [])

    def test_down_spares_a_reused_pid_whose_command_lacks_port_forward(self):
        sleeper = self.start_process(["/bin/sleep", "60"])
        self.write_state(forward_pid=sleeper.pid, port=self.port)

        self.assert_ok(self.invoke("down"))

        with self.assertRaises(subprocess.TimeoutExpired):
            sleeper.wait(timeout=0.5)

    def test_down_spares_a_port_forward_for_another_workspace(self):
        other = f"devbox-{USER}-other"
        self.add_box(other)
        forward = self.start_fake_forward(other, self.fallback_ports[0])
        self.write_state(forward_pid=forward.pid, port=self.fallback_ports[0])

        self.assert_ok(self.invoke("down"))

        with self.assertRaises(subprocess.TimeoutExpired):
            forward.wait(timeout=0.5)

    def test_down_with_a_dead_forward_pid_succeeds(self):
        finished = self.start_process(["/usr/bin/true"])
        finished.wait()
        self.write_state(forward_pid=finished.pid, port=self.port)

        self.assert_ok(self.invoke("down"))

        self.assertFalse(self.state_path.exists())

    def test_failing_stop_is_not_run_and_keeps_the_state_for_a_retry(self):
        self.write_state(started_by_step=True)
        self.assert_ok(self.invoke("forward"))
        pid = self.read_state()["forward_pid"]
        self.set_behavior("hogli devbox:stop", exit=1, stderr="coder stop failed\n")

        self.assert_not_run(self.invoke("down"))

        self.assertTrue(wait_until(lambda: not pid_running(pid)), "the forward survived down")
        self.assertEqual(
            {key: self.read_state()[key] for key in ("started_by_step", "forward_pid", "port")},
            {"started_by_step": True, "forward_pid": None, "port": None},
        )
        self.world["behaviors"] = {}
        self.save_world()
        self.clear_calls()

        self.assert_ok(self.invoke("down"))

        self.assertEqual(self.devbox_calls(), [("devbox:stop", "-n", LABEL)])
        self.assertFalse(self.state_path.exists())

    def test_down_refuses_to_stop_a_box_the_record_no_longer_proves(self):
        self.write_state(started_by_step=True)
        self.world["workspaces"][WORKSPACE]["id"] = workspace_id("a box made later under the same name")
        self.save_world()

        self.assert_not_run(self.invoke("down"))

        self.assertEqual(self.devbox_calls(), [])
        self.assertTrue(self.state_path.exists())

    def test_down_without_state_is_a_no_op(self):
        self.assert_ok(self.invoke("down"))

        self.assertEqual(self.devbox_calls(), [])
        self.assertEqual([sub for sub in self.coder_subcommands() if sub in ("ssh", "port-forward")], [])

    def test_down_refuses_to_stop_a_box_that_state_does_not_name_as_a_labeled_box(self):
        for workspace, label in ((MAIN_BOX, ""), (EU_MAIN_BOX, "eu")):
            with self.subTest(workspace=workspace):
                self.reset()
                self.write_state(workspace=workspace, label=label, started_by_step=True)

                self.assert_not_run(self.invoke("down"))
                self.assertEqual(self.devbox_calls(), [])


class HungPsTests(DevboxStackTestCase):
    """Risk 4: a `ps` that never answers leaves the recorded forward alone and does not stall the run."""

    def setUp(self):
        super().setUp()
        self.write_executable(self.shims / "ps", "#!/bin/sh\nexec /bin/sleep 30\n")
        self.forward_process = self.start_fake_forward(WORKSPACE, self.port)
        self.write_state(forward_pid=self.forward_process.pid, port=self.port, started_by_step=True)

    def assert_forward_untouched(self, command):
        started = time.monotonic()

        result = self.invoke(command, overrides={"PS_TIMEOUT": 0.5})

        self.assertLess(time.monotonic() - started, 10)
        payload = self.assert_not_run(result)
        self.assertIn(str(self.forward_process.pid), payload["unblock"])
        self.assertIsNone(self.forward_process.poll())
        self.assertEqual(health_status(self.port), 200)
        self.assertEqual(self.read_state()["forward_pid"], self.forward_process.pid)
        self.assertEqual(self.devbox_calls(), [])

    def test_down_with_a_hung_ps_kills_nothing_and_keeps_the_state(self):
        self.assert_forward_untouched("down")

    def test_forward_with_a_hung_ps_kills_nothing_and_starts_no_forward(self):
        self.assert_forward_untouched("forward")

        self.assertNotIn("port-forward", self.coder_subcommands())


class FlowTests(DevboxStackTestCase):
    def test_preflight_up_forward_down_against_the_fakes(self):
        self.stop_labeled_box()
        self.world["demo_user"] = False
        self.save_world()

        self.assert_ok(self.invoke("preflight"))
        self.assert_ok(self.up())
        url = self.assert_ok(self.invoke("forward"))["url"]
        served = health_status(self.port)
        pid = self.read_state()["forward_pid"]
        self.assert_ok(self.invoke("down"))

        self.assertEqual(url, f"http://localhost:{self.port}")
        self.assertEqual(served, 200)
        self.assertEqual([call for call in self.hogli_log() if call != ("--help",)], EXPECTED_FLOW_HOGLI_LOG)
        self.assertTrue(wait_until(lambda: not pid_running(pid)), "the forward survived down")
        self.assertEqual(self.load_world()["workspaces"][WORKSPACE]["status"], "stopped")
        self.assertFalse(self.state_path.exists())


if __name__ == "__main__":
    unittest.main()
