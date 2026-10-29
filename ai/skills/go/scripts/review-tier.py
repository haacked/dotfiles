#!/usr/bin/env python3
"""Decide whether go's fix-commit review or Final simplify runs over a commit range."""

import argparse
import fnmatch
import json
import re
import subprocess
import sys


FIX_REVIEW_MAX_LINES = 100
FINAL_SIMPLIFY_MAX_LINES = 20

PROMPT_NAMES = {
    "skill.md",
    "agents.md",
    "claude.md",
    "gemini.md",
    "copilot-instructions.md",
    ".cursorrules",
}
PROMPT_SEGMENTS = {
    "skills",
    "agents",
    "commands",
    "prompts",
    "handlers",
    "contexts",
    "rules",
    "evals",
    ".claude",
    ".cursor",
}
TEST_SEGMENTS = {"test", "tests", "__tests__", "spec", "testdata"}
TEST_NAME = re.compile(
    r"test_.*\.py|conftest\.py|.*_test\.go|.*_spec\.rb|.*\.(test|spec)\.(js|jsx|ts|tsx|mjs|cjs)"
)
DOCS_EXTENSIONS = (".md", ".mdx", ".rst", ".adoc")
DOCS_PREFIXES = ("README", "CHANGELOG", "LICENSE")

API_SEGMENTS = {"api", "openapi", "serializers", "sdk"}
WIRE_EXTENSIONS = (".proto", ".avsc", ".capnp", ".thrift", ".fbs")
AUTH_WORDS = (
    "auth",
    "permission",
    "access_control",
    "access-control",
    "rbac",
    "csrf",
    "cors",
    "secret",
    "credential",
    "crypt",
    "password",
    "security",
    "saml",
    "sso",
)
INFRA_SEGMENTS = {
    "charts",
    "helm",
    "terraform",
    "k8s",
    "kubernetes",
    "argocd",
    ".github",
    "deploy",
    "infra",
}
DEPENDENCY_NAMES = {
    "package.json",
    "package-lock.json",
    "pnpm-lock.yaml",
    "yarn.lock",
    "pyproject.toml",
    "poetry.lock",
    "uv.lock",
    "pipfile",
    "pipfile.lock",
    "cargo.toml",
    "cargo.lock",
    "go.mod",
    "go.sum",
    "gemfile",
    "gemfile.lock",
}
DATA_DELETION = re.compile(
    r"\bDELETE\s+FROM\b|\bDROP\s+(TABLE|COLUMN|DATABASE|INDEX)\b|\bTRUNCATE\s+TABLE\b|\bALTER\s+TABLE\b|\brm\s+-rf\b",
    re.IGNORECASE,
)
STATUS_REASONS = {
    "R": "uncertain-rename",
    "C": "uncertain-copy",
    "D": "uncertain-deleted-file",
    "T": "uncertain-type-change",
}
SUBMODULE_MODE = "160000"
SYMLINK_MODE = "120000"


def git(*args):
    return subprocess.run(
        ["git", *args], check=True, capture_output=True
    ).stdout.decode(errors="replace")


def split_path(path):
    parts = path.split("/")
    return parts[:-1], parts[-1]


def file_class(path):
    # A file counts as docs or tests only when its name says so.
    # Any file the rules do not recognize counts as code, so the review runs.
    segments, name = split_path(path)
    lowered = {segment.lower() for segment in segments}
    lower_name = name.lower()
    if lower_name in PROMPT_NAMES:
        return "code"
    if lowered & TEST_SEGMENTS or TEST_NAME.fullmatch(name):
        return "test"
    if lowered & PROMPT_SEGMENTS:
        return "code"
    suffix = lower_name.rpartition(".")[2] if "." in lower_name else ""
    if lower_name.endswith(DOCS_EXTENSIONS) or (
        name.startswith(DOCS_PREFIXES) and suffix in {"", "txt"}
    ):
        return "docs"
    return "code"


def path_risks(path):
    segments, name = split_path(path)
    lowered = {segment.lower() for segment in segments}
    lower_name = name.lower()
    lower_path = path.lower()
    risks = []
    if (
        any("migration" in segment for segment in lowered)
        or "alembic" in lowered
        or lower_name.endswith(".sql")
    ):
        risks.append("risky-migration")
    if lowered & API_SEGMENTS or lower_name.endswith(".graphql"):
        risks.append("risky-api")
    if lower_name.endswith(WIRE_EXTENSIONS):
        risks.append("risky-wire-format")
    if any(word in lower_path for word in AUTH_WORDS):
        risks.append("risky-auth")
    if (
        lowered & INFRA_SEGMENTS
        or lower_name.endswith((".tf", ".tfvars"))
        or lower_name.startswith(("dockerfile", "docker-compose"))
        or (lower_name.startswith("values") and lower_name.endswith((".yaml", ".yml")))
    ):
        risks.append("risky-infra")
    if lower_name in DEPENDENCY_NAMES or fnmatch.fnmatch(
        lower_name, "requirements*.txt"
    ):
        risks.append("risky-dependency")
    return [f"{risk}: {path}" for risk in risks]


def raw_entries(base, head):
    fields = git(
        "diff", "--no-ext-diff", "--no-textconv", "--raw", "-z", "-M", "-C", base, head
    ).split("\0")
    entries = []
    index = 0
    while index < len(fields) and fields[index]:
        old_mode, new_mode, _, _, status = fields[index][1:].split(" ")
        paths = 2 if status[0] in "RC" else 1
        entries.append(
            {
                "old_mode": old_mode,
                "new_mode": new_mode,
                "status": status[0],
                "path": fields[index + paths],
            }
        )
        index += 1 + paths
    return entries


def line_counts(base, head):
    fields = git(
        "diff", "--no-ext-diff", "--no-textconv", "--numstat", "-z", "-M", "-C", base, head
    ).split("\0")
    counts = {}
    index = 0
    while index < len(fields) and fields[index]:
        added, removed, path = fields[index].split("\t", 2)
        if path:
            index += 1
        else:
            path = fields[index + 2]
            index += 3
        counts[path] = (
            None if added == "-" else (int(added), int(removed))
        )
    return counts


def added_lines(base, head):
    in_hunk = False
    patch = git(
        "diff", "--no-ext-diff", "--no-textconv", "--unified=0", "--no-color", base, head
    )
    for line in patch.splitlines():
        if line.startswith("diff --git "):
            in_hunk = False
        elif line.startswith("@@"):
            in_hunk = True
        elif in_hunk and line.startswith("+"):
            yield line[1:]


def uncertain_reasons(entry, counts):
    path = entry["path"]
    modes = {entry["old_mode"], entry["new_mode"]}
    reasons = [STATUS_REASONS[entry["status"]]] if entry["status"] in STATUS_REASONS else []
    if entry["status"] == "M" and entry["old_mode"] != entry["new_mode"]:
        reasons.append("uncertain-mode-change")
    if SUBMODULE_MODE in modes:
        reasons.append("uncertain-submodule")
    if SYMLINK_MODE in modes:
        reasons.append("uncertain-symlink")
    if counts.get(path, (0, 0)) is None:
        reasons.append("uncertain-binary")
    return [f"{reason}: {path}" for reason in reasons]


def decide(purpose, base, head):
    result = {"purpose": purpose, "base": base, "head": head}
    try:
        entries = raw_entries(base, head)
        counts = line_counts(base, head)
        deletions = purpose == "fix-review" and any(
            DATA_DELETION.search(line) for line in added_lines(base, head)
        )
    except (subprocess.CalledProcessError, ValueError, IndexError) as error:
        message = getattr(error, "stderr", None) or str(error).encode()
        first_line = message.decode(errors="replace").strip().partition("\n")[0]
        return result | {
            "tier": "full",
            "reasons": [f"uncertain-diff-failed: {first_line}"],
            "stats": {"lines": 0, "files": 0},
        }
    lines = sum(sum(count) for count in counts.values() if count)
    result["stats"] = {"lines": lines, "files": len(entries)}

    uncertain = []
    risky = []
    shape = []
    classes = set()
    for entry in entries:
        path = entry["path"]
        uncertain += uncertain_reasons(entry, counts)
        if purpose == "fix-review":
            risky += path_risks(path)
        kind = file_class(path)
        classes.add(kind)
        if kind == "code":
            shape.append(f"code-file: {path}")
        count = counts.get(path)
        if kind == "test" and count and count[1] > count[0]:
            shape.append(f"test-lines-removed: {path}")
    if deletions:
        risky.append("risky-data-deletion")

    if purpose == "fix-review":
        reasons = risky + uncertain + shape
        limit = FIX_REVIEW_MAX_LINES
    else:
        reasons = uncertain
        # A docs-only change skips Final simplify at any size.
        limit = None if classes == {"docs"} else FINAL_SIMPLIFY_MAX_LINES
    if limit is not None and lines > limit:
        reasons.append(f"too-large: {lines} lines, over {limit}")
    return result | {"tier": "full" if reasons else "skip", "reasons": reasons}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--purpose", choices=["fix-review", "final-simplify"], required=True
    )
    parser.add_argument("--base", required=True)
    parser.add_argument("--head", default="HEAD")
    args = parser.parse_args()
    print(json.dumps(decide(args.purpose, args.base, args.head)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
