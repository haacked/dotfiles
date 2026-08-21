#!/usr/bin/env python3
"""Render Claude Markdown agent definitions as Codex TOML agents."""

from __future__ import annotations

import json
import pathlib
import re
import sys


MANAGED_HEADER = "# Managed by ~/.dotfiles/ai/install-codex.sh.\n"


def load_model_tiers() -> tuple[
    dict[str, tuple[str, str]], dict[str, tuple[str, str, str]]
]:
    config_path = pathlib.Path(__file__).parent.parent / "codex" / "model-tiers.conf"
    model_map: dict[str, tuple[str, str]] = {}
    tier_map: dict[str, tuple[str, str, str]] = {}
    for line in config_path.read_text().splitlines():
        if not line or line.startswith("#"):
            continue
        try:
            tier, claude_model, codex_model, effort = line.split("|")
        except ValueError:
            raise ValueError(f"{config_path}: malformed row {line!r}") from None
        model_map[claude_model] = (codex_model, effort)
        tier_map[tier] = (claude_model, codex_model, effort)
    return model_map, tier_map


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


def render(path: pathlib.Path, model_map: dict[str, tuple[str, str]]) -> str:
    metadata, body = parse_agent(path)
    lines = [
        MANAGED_HEADER.rstrip(),
        f"name = {json.dumps(metadata['name'])}",
        f"description = {json.dumps(metadata['description'])}",
    ]
    model = metadata.get("model", "inherit")
    if model != "inherit":
        if model not in model_map:
            raise ValueError(
                f"{path}: unknown model {model!r}; add a row for it to codex/model-tiers.conf"
            )
        codex_model, effort = model_map[model]
        lines.extend(
            [
                f"model = {json.dumps(codex_model)}",
                f"model_reasoning_effort = {json.dumps(effort)}",
            ]
        )
    lines.append(f"developer_instructions = {json.dumps(body)}")
    return "\n".join(lines) + "\n"


def render_skill_runner(tier: str, codex_model: str, effort: str) -> str:
    description = f"Runs a requested {tier}-tier skill with its configured Codex model."
    instructions = "Read the requested skill completely, follow its workflow exactly, and return its required result to the parent agent."
    return "\n".join(
        [
            MANAGED_HEADER.rstrip(),
            f'name = "skill-runner-{tier}"',
            f"description = {json.dumps(description)}",
            f"model = {json.dumps(codex_model)}",
            f"model_reasoning_effort = {json.dumps(effort)}",
            f"developer_instructions = {json.dumps(instructions)}",
            "",
        ]
    )


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} SOURCE_DIR OUTPUT_DIR", file=sys.stderr)
        return 2

    source_dir = pathlib.Path(sys.argv[1])
    output_dir = pathlib.Path(sys.argv[2])
    output_dir.mkdir(parents=True, exist_ok=True)
    expected: set[pathlib.Path] = set()
    model_map, tier_map = load_model_tiers()

    for source in sorted(source_dir.glob("*.md")):
        destination = output_dir / f"{source.stem}.toml"
        destination.write_text(render(source, model_map))
        expected.add(destination)

    for tier, (_, codex_model, effort) in tier_map.items():
        destination = output_dir / f"skill-runner-{tier}.toml"
        destination.write_text(render_skill_runner(tier, codex_model, effort))
        expected.add(destination)

    for destination in output_dir.glob("*.toml"):
        if destination not in expected and destination.read_text().startswith(
            MANAGED_HEADER
        ):
            destination.unlink()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
