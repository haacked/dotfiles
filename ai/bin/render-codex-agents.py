#!/usr/bin/env python3
"""Render Claude Markdown agent definitions as Codex TOML agents."""

from __future__ import annotations

import json
import pathlib
import sys

from agent_definitions import parse_agent


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
