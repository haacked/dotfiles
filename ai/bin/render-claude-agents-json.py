#!/usr/bin/env python3
"""Print Claude Markdown agent definitions as the JSON that `claude --agents` takes."""

from __future__ import annotations

import json
import pathlib
import sys

from agent_definitions import parse_agent


def main() -> int:
    if len(sys.argv) < 2:
        print(f"Usage: {sys.argv[0]} AGENT_FILE...", file=sys.stderr)
        return 2

    agents: dict[str, dict[str, str]] = {}
    for arg in sys.argv[1:]:
        try:
            metadata, body = parse_agent(pathlib.Path(arg))
        except (OSError, ValueError) as error:
            print(error, file=sys.stderr)
            return 1
        name = metadata.pop("name")
        agents[name] = {**metadata, "prompt": body.strip()}

    print(json.dumps(agents))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
