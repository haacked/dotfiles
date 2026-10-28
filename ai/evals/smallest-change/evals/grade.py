"""Grades an eval workspace after the agent stops and writes eval-result.txt for the case's regex graders.

Usage: grade.py <workspace>

grade.json in the same folder sets `max_lines`, the most production lines the change may add or remove, and optionally `require_added`, a map from a file path to a regex that some added line in that file must match.
"""

import json
import os
import re
import subprocess
import sys
from pathlib import Path

RESULT = "eval-result.txt"
DEPENDENCY_FILES = re.compile(r"(^|/)(pyproject\.toml|setup\.py|setup\.cfg|Pipfile|requirements[^/]*\.txt)$")


def git(root, *args):
    return subprocess.run(["git", *args], cwd=root, capture_output=True, text=True, check=True).stdout


def is_test(path):
    return path.startswith("tests/") or Path(path).name.startswith("test_")


def run_tests(root, start_dir, top_dir):
    env = {**os.environ, "PYTHONPATH": str(root), "PYTHONDONTWRITEBYTECODE": "1"}
    result = subprocess.run(
        [sys.executable, "-m", "unittest", "discover", "-s", start_dir, "-t", top_dir],
        cwd=root,
        env=env,
        capture_output=True,
        text=True,
        timeout=120,
    )
    return result.returncode == 0, result.stderr[-2000:]


def main():
    root = Path(sys.argv[1])
    config = json.loads((Path(__file__).parent / "grade.json").read_text())
    base = (Path(__file__).parent / "base").read_text().strip()

    hidden_ok, hidden_log = run_tests(root, ".eval/hidden", ".eval/hidden")
    repo_ok, repo_log = run_tests(root, "tests", ".")

    # Intent-to-add makes new files show up in `git diff` without staging their contents.
    git(root, "add", "-N", "--", ".", f":!{RESULT}")
    changed = []
    for line in git(root, "diff", "--numstat", base, "--", ".", f":!{RESULT}").splitlines():
        added, removed, path = line.split("\t", 2)
        changed.append((path, int(added) if added != "-" else 0, int(removed) if removed != "-" else 0))

    production_lines = sum(a + r for path, a, r in changed if not is_test(path))
    dependency_files = [path for path, _, _ in changed if DEPENDENCY_FILES.search(path)]

    lines = [
        f"hidden_tests: {'pass' if hidden_ok and repo_ok else 'fail'}",
        f"size: {'ok' if production_lines <= config['max_lines'] else 'over'}",
        f"production_lines_changed: {production_lines} (limit {config['max_lines']})",
        f"dependencies: {'changed' if dependency_files else 'unchanged'}",
    ]
    if config.get("require_added"):
        missing = []
        for path, pattern in config["require_added"].items():
            added_lines = [
                l[1:] for l in git(root, "diff", "-U0", base, "--", path).splitlines()
                if l.startswith("+") and not l.startswith("+++")
            ]
            if not any(re.search(pattern, l) for l in added_lines):
                missing.append(path)
        lines.append(f"expected_code: {'missing in ' + ', '.join(missing) if missing else 'ok'}")
    lines.append(f"changed_files: {', '.join(path for path, _, _ in changed) or 'none'}")
    if not hidden_ok:
        lines += ["", "hidden test output:", hidden_log]
    if not repo_ok:
        lines += ["", "repo test output:", repo_log]

    (root / RESULT).write_text("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
