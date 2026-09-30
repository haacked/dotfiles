"""Parse the Claude Markdown agent definitions in ai/agents/."""

from __future__ import annotations

import json
import pathlib
import re


def parse_agent(path: pathlib.Path) -> tuple[dict[str, str], str]:
    text = path.read_text()
    match = re.match(r"\A---\n(.*?)\n---\n?(.*)\Z", text, re.DOTALL)
    if not match:
        raise ValueError(f"{path}: missing YAML frontmatter")

    metadata: dict[str, str] = {}
    for line in match.group(1).splitlines():
        if line[:1].isspace():
            raise ValueError(f"{path}: multiline frontmatter is not supported")
        key, separator, value = line.partition(":")
        if not separator or key not in {"name", "description", "model"}:
            continue
        value = value.strip()
        if value.startswith("'"):
            raise ValueError(f"{path}: single-quoted frontmatter is not supported")
        if value.startswith('"') and value.endswith('"'):
            value = json.loads(value)
        metadata[key] = value

    for required in ("name", "description"):
        if not metadata.get(required):
            raise ValueError(f"{path}: missing {required}")
    return metadata, match.group(2).strip() + "\n"
