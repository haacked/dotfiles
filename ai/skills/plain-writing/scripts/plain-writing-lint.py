#!/usr/bin/env python3
"""Report mechanical plain-writing warnings without scoring the prose."""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path
from typing import Iterable, TypedDict

RAW_PATTERNS: dict[str, tuple[str, ...]] = {
    "filler": (
        r"\blet(?:'|’)s (?:dive in|dive into|explore|break this down)\b",
        r"\bhere(?:'|’)s what you need to know\b",
        r"\bit is (?:important|worth) to note\b",
        r"\bin order to\b",
        r"\bdue to the fact that\b",
        r"\bat this point in time\b",
        r"\bin the event that\b",
        r"\bi hope this helps\b",
        r"\blet me know\b",
    ),
    "hype": (
        r"\b(?:robust|seamless|powerful|pivotal|groundbreaking|revolutionary)\b",
        r"\b(?:world-class|cutting-edge|effortless|game-changing|best-in-class)\b",
        r"\bcomprehensive\b",
    ),
    "jargon": (
        r"\b(?:leverage|leverages|leveraged|leveraging)\b",
        r"\b(?:utilize|utilizes|utilized|utilizing|utilization)\b",
        r"\b(?:facilitate|facilitates|facilitated|facilitating)\b",
        r"\b(?:navigate|navigates|navigated|navigating)\b",
    ),
}

# Compiled once at import so the per-line loop below only dispatches matches, the same
# way every other regex in this module is handled.
PATTERNS: dict[str, tuple[re.Pattern[str], ...]] = {
    category: tuple(re.compile(pattern, re.I) for pattern in patterns)
    for category, patterns in RAW_PATTERNS.items()
}

CONTRACTION = re.compile(
    r"\b(?:[A-Za-z]+n['’]t|(?:i|you|we|they|he|she|it|that|there|what|who|let)['’](?:re|ve|ll|d|m|s))\b",
    re.I,
)
INLINE_CODE = re.compile(r"`[^`]*`")
URL = re.compile(r"https?://[^\s)>]+")
WORD = re.compile(r"[A-Za-z0-9][A-Za-z0-9'’/-]*")
FENCE = re.compile(r"^ {0,3}(`{3,}|~{3,})")
SENTENCE_SPLIT = re.compile(r"(?<=[.!?])\s+")
FRONTMATTER_DELIMITER = "---"


class LintWarning(TypedDict):
    line: int
    category: str
    message: str
    text: str


def prose_lines(text: str) -> Iterable[tuple[int, str, str]]:
    """Yield Markdown prose with code masked and original line numbers intact."""
    lines = text.splitlines()
    start = 0
    # YAML frontmatter is metadata, not prose; linting it flags a skill's own
    # description field. Only a delimiter on the first line opens a frontmatter block,
    # so a horizontal rule later in the document still lints normally.
    if lines and lines[0].strip() == FRONTMATTER_DELIMITER:
        for index, line in enumerate(lines[1:], start=1):
            if line.strip() == FRONTMATTER_DELIMITER:
                start = index + 1
                break

    fence = ""
    for line_number, line in enumerate(lines[start:], start=start + 1):
        marker = FENCE.match(line)
        token = marker.group(1) if marker else ""
        if fence:
            # A closing fence repeats the opening character at least as many times and
            # carries nothing after it.
            if (
                marker
                and token.startswith(fence)
                and not line[marker.end() :].strip()
            ):
                fence = ""
            continue
        if token:
            fence = token
            continue
        yield line_number, line, URL.sub("", INLINE_CODE.sub("", line))


def warning(line: int, category: str, message: str, text: str) -> LintWarning:
    return {
        "line": line,
        "category": category,
        "message": message,
        "text": text.strip(),
    }


def lint(text: str, strict: bool = False) -> list[LintWarning]:
    warnings: list[LintWarning] = []
    sentence_limit = 20 if strict else 30

    for line_number, original, prose in prose_lines(text):
        stripped = prose.strip()
        if not stripped:
            continue

        for category, patterns in PATTERNS.items():
            if any(pattern.search(prose) for pattern in patterns):
                warnings.append(
                    warning(
                        line_number,
                        category,
                        f"Possible {category}; use concrete, direct wording.",
                        original,
                    )
                )

        if "—" in prose or "–" in prose:
            warnings.append(
                warning(
                    line_number,
                    "em_dash",
                    "Restructure the sentence without an em dash or en dash.",
                    original,
                )
            )

        for sentence in SENTENCE_SPLIT.split(stripped):
            word_count = len(WORD.findall(sentence))
            if word_count > sentence_limit:
                warnings.append(
                    warning(
                        line_number,
                        "long_sentence",
                        (
                            f"Sentence has {word_count} words; check whether it needs "
                            "two sentences."
                        ),
                        sentence,
                    )
                )

        if strict and ";" in prose:
            warnings.append(
                warning(
                    line_number,
                    "semicolon",
                    "Strict mode uses separate sentences instead of semicolons.",
                    original,
                )
            )
        if strict and CONTRACTION.search(prose):
            warnings.append(
                warning(
                    line_number,
                    "contraction",
                    "Strict mode does not use contractions.",
                    original,
                )
            )

    return warnings


def render_text(path: str, warnings: list[LintWarning]) -> str:
    if not warnings:
        return f"{path}: no mechanical warnings"
    return "\n".join(
        f"{path}:{item['line']}: {item['category']}: {item['message']}"
        for item in warnings
    )


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "files", nargs="*", help="Markdown or text files; read stdin when omitted"
    )
    parser.add_argument(
        "--strict", action="store_true", help="Apply procedure and error-message checks"
    )
    parser.add_argument("--json", action="store_true", help="Print JSON results")
    parser.add_argument(
        "--fail-on-warnings",
        action="store_true",
        help="Exit 1 when warnings exist; warnings do not fail by default",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    inputs = args.files or ["-"]
    results: list[tuple[str, list[LintWarning]]] = []

    for name in inputs:
        text = (
            sys.stdin.read() if name == "-" else Path(name).read_text(encoding="utf-8")
        )
        results.append((name, lint(text, strict=args.strict)))

    if args.json:
        payload = [
            {"file": name, "strict": args.strict, "warnings": warnings}
            for name, warnings in results
        ]
        print(json.dumps(payload[0] if len(payload) == 1 else payload, indent=2))
    else:
        for name, warnings in results:
            print(render_text(name, warnings))

    has_warnings = any(warnings for _, warnings in results)
    return 1 if args.fail_on_warnings and has_warnings else 0


if __name__ == "__main__":
    raise SystemExit(main())
