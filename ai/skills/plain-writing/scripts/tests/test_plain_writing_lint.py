#!/usr/bin/env python3
"""Behavior tests for plain-writing-lint.py."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[1] / "plain-writing-lint.py"


def load_linter():
    spec = importlib.util.spec_from_file_location("plain_writing_lint", SCRIPT)
    assert spec is not None and spec.loader is not None
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


lint = load_linter().lint


def categories(warnings: list[dict[str, object]]) -> set[str]:
    return {warning["category"] for warning in warnings}


class PlainWritingLintTests(unittest.TestCase):
    def test_flags_filler_hype_and_dense_sentences(self) -> None:
        text = (
            "Let's dive into this robust and seamless workflow, which provides a "
            "comprehensive foundation that enables teams to leverage the platform "
            "while navigating a rapidly evolving technical landscape without any "
            "additional setup or operational changes."
        )

        result = lint(text)

        self.assertTrue(
            {"filler", "hype", "jargon", "long_sentence"} <= categories(result)
        )

    def test_ignores_fenced_and_inline_code(self) -> None:
        text = """Use `leverage()` when the API requires it.

```python
def leverage_robust_platform():
    return "seamless"
```
"""

        result = lint(text)

        self.assertEqual(result, [])

    def test_ignores_nested_and_tilde_fences(self) -> None:
        text = """````markdown
```text
robust
```
````

~~~python
leverage = True
~~~
"""

        self.assertEqual(lint(text), [])

    def test_ignores_words_inside_urls(self) -> None:
        result = lint("Read https://example.com/robust-leverage-guide.")

        self.assertEqual(result, [])

    def test_preserves_line_numbers_after_fenced_code(self) -> None:
        text = """Clear opening.

```text
robust
```

This seamless process works.
"""

        warnings = lint(text)

        self.assertEqual(len(warnings), 1)
        self.assertEqual(warnings[0]["line"], 7)
        self.assertEqual(warnings[0]["category"], "hype")

    def test_strict_mode_adds_contractions_and_semicolons(self) -> None:
        normal = lint("Don't stop; retry the request.")
        strict = lint("Don't stop; retry the request.", strict=True)

        self.assertEqual(normal, [])
        self.assertEqual(categories(strict), {"contraction", "semicolon"})

    def test_strict_mode_does_not_treat_possessives_as_contractions(self) -> None:
        result = lint("Restart the server's worker.", strict=True)

        self.assertEqual(result, [])

    def test_em_dash_is_always_flagged(self) -> None:
        result = lint("The request succeeds — the cache remains stale.")

        self.assertEqual(categories(result), {"em_dash"})

    def test_cli_warns_without_failing_unless_requested(self) -> None:
        command = [sys.executable, str(SCRIPT), "--json"]
        warning_only = subprocess.run(
            command,
            input="This robust process works.",
            check=False,
            capture_output=True,
            text=True,
        )
        fail_on_warnings = subprocess.run(
            [*command, "--fail-on-warnings"],
            input="This robust process works.",
            check=False,
            capture_output=True,
            text=True,
        )

        self.assertEqual(warning_only.returncode, 0)
        self.assertEqual(fail_on_warnings.returncode, 1)
        self.assertEqual(json.loads(warning_only.stdout)["warnings"][0]["line"], 1)

    def test_cli_reads_file_and_renders_default_output(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "draft.md"
            path.write_text("This robust process works.", encoding="utf-8")
            completed = subprocess.run(
                [sys.executable, str(SCRIPT), str(path)],
                check=False,
                capture_output=True,
                text=True,
            )

        self.assertEqual(completed.returncode, 0)
        self.assertEqual(
            completed.stdout,
            f"{path}:1: hype: Possible hype; use concrete, direct wording.\n",
        )


if __name__ == "__main__":
    unittest.main()
