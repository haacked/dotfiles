#!/usr/bin/env python3
"""Behavior tests for plain-writing-lint.py."""

from __future__ import annotations

import importlib.util
import json
import subprocess
import sys
import tempfile
import time
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

    def test_flags_negative_parallelism(self) -> None:
        for text in (
            "It's not just a linter, it's a style guide.",
            "This isn't about speed, it's about correctness.",
            "The change is not merely a rename, it is a behavior change.",
            "These are not just warnings, they are errors.",
            "Not only a cache, but a full index.",
            "It\u2019s not only slower, it\u2019s wrong.",
        ):
            with self.subTest(text=text):
                self.assertIn("negative_parallelism", categories(lint(text)))

    def test_plain_negation_is_not_negative_parallelism(self) -> None:
        for text in (
            "The flag is not set, so the skill loads normally.",
            "Do not use this for local dev investigations.",
            "This is not just wrong.",
            "The value is not merely cached, so a refetch is cheap.",
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_flags_trailing_participle(self) -> None:
        for text in (
            "The rollout stalled, highlighting the need for better tests.",
            "Latency doubled, underscoring how fragile the cache is.",
            "Adoption grew, demonstrating the value of the approach.",
        ):
            with self.subTest(text=text):
                self.assertIn("trailing_participle", categories(lint(text)))

    def test_mid_sentence_aside_is_not_a_trailing_participle(self) -> None:
        for text in (
            "The report, highlighting three defects, was filed on Monday.",
            "We are reflecting on the outcome.",
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_flags_negative_subject(self) -> None:
        for text in (
            "Nothing changes that wasn't already existing.",
            "Nothing else reads it.",
            "Nothing in this PR changes the schema.",
            "Nothing should happen.",
            "No test covers the expired token case.",
            "No caller depends on the old name.",
            "No changes are needed.",
            "No existing test covers the expired token case.",
            "No tests exercise this path.",
            "No tests use the old name.",
            "No other caller uses it.",
            "No other way is possible.",
            "No idea is too small.",
            "No caller that uses it remains.",
            "No user who has access can see it.",
            "Nothing is ever easy.",
        ):
            with self.subTest(text=text):
                self.assertIn("negative_subject", categories(lint(text)))

    def test_flags_negative_subject_at_every_sentence_opening(self) -> None:
        for opening in (
            "- ",
            "1. ",
            "  - ",
            "The flag is off. ",
            "**The flag is off.** ",
            "`nit`: ",
            "**nit:** ",
            "_nit:_ ",
            "The flag is off; ",
            "(The flag is off.) ",
            'The flag is "off." ',
            "The flag is “off.” ",
            "The flag is 'off.' ",
            "The flag is ‘off.’ ",
            "[The flag is off.] ",
            "~~The flag is off.~~ ",
        ):
            for sentence in (
                "Nothing else reads it.",
                "No caller depends on the old name.",
                "nothing was written to disk.",
            ):
                text = opening + sentence
                with self.subTest(text=text):
                    self.assertIn("negative_subject", categories(lint(text)))

    def test_plain_negation_is_not_a_negative_subject(self) -> None:
        for text in (
            "It doesn't change anything that already exists.",
            "There's nothing else to do.",
            "Nobody is working on this.",
            "No one has asked.",
            "No, that's expected.",
            "No it is not.",
            "No this is expected.",
            "No they are not.",
            "No I have not.",
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_fragment_or_idiom_is_not_a_negative_subject(self) -> None:
        for text in (
            "Nothing to note in the release notes.",
            "Nothing in production.",
            "Nothing serious, just a nit.",
            "Nothing less than a rewrite.",
            "Nothing as far as I can tell.",
            "Nothing besides the docs.",
            "No unit tests yet.",
            "No behavioral changes in this PR.",
            "No breaking changes.",
            "No idea why this happens.",
            "No idea what is going on.",
            "No clue what is going on.",
            "No doubt this is faster.",
            "No way this is right.",
            "No wonder this is slow.",
            "No surprise there is a bug.",
            "No need to touch this file.",
            "- No longer depends on the old helper.",
            "No matter what is chosen, the request retries.",
            "Nothing this week.",
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_negative_word_away_from_a_sentence_opening_is_not_flagged(self) -> None:
        for text in (
            "We found that no caller depends on the old name.",
            "The flag is off, and nothing else reads it.",
            "> Nothing changes here.",
            "> No caller depends on the old name.",
            "ratio:Nothing else reads it.",
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_new_categories_carry_their_own_message(self) -> None:
        generic = lint("This robust process works.")[0]["message"]
        specific = lint("It's not just a linter, it's a style guide.")[0]["message"]

        self.assertEqual(
            generic, "Possible hype; use concrete, direct wording."
        )
        self.assertEqual(
            specific,
            "Denies a smaller claim to set up the real one; state what is true.",
        )

    def test_subject_checks_carry_their_own_messages(self) -> None:
        for category, text, message in (
            (
                "negative_subject",
                "No caller depends on the old name.",
                'Opens with "Nothing" or "No X" as the subject; start with what '
                "the sentence is about and negate the verb.",
            ),
            (
                "quoted_subject",
                '"legacy" names two different hashes here.',
                "A quoted word can't name, decide, or want anything; say what the "
                "word means or where it appears.",
            ),
        ):
            with self.subTest(category=category):
                messages = [
                    warning["message"]
                    for warning in lint(text)
                    if warning["category"] == category
                ]

                self.assertEqual(messages, [message])

    def test_flags_quoted_subject(self) -> None:
        for text in (
            '"legacy" names two different hashes here.',
            "“legacy” names two different hashes here.",
            '`suggestion`: "legacy" names two different hashes here.',
            '- "beta" decides which variant to serve.',
            'The flag is off. "legacy" wants a rename.',
            '(The flag is off.) "legacy" wants a rename.',
            '"missed the loader cache" names a code object.',
        ):
            with self.subTest(text=text):
                self.assertIn("quoted_subject", categories(lint(text)))

    def test_quoted_subject_flags_only_its_listed_verbs(self) -> None:
        for text in (
            '"legacy" means two different things here.',
            '"Questions?" links to the FAQ.',
            '"Link File References" runs after the gate.',
            '"Milestone 0" holds the checklist for this step.',
            '"auth" namespaces every key.',
            '"Rename the flag." Names should describe behavior.',
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_quoted_word_away_from_a_sentence_opening_is_not_flagged(self) -> None:
        for text in (
            'The names of both hashes contain "legacy".',
            'It was rewritten because "the offset" names the thing that changes state.',
            'The toolkit\'s "what usually breaks" names it first.',
        ):
            with self.subTest(text=text):
                self.assertEqual(lint(text), [])

    def test_code_subject_is_not_a_quoted_subject(self) -> None:
        result = lint("`resolve_flag` decides which variant to serve.")

        self.assertEqual(result, [])

    def test_quoted_subject_stays_fast_on_unclosed_curly_quotes(self) -> None:
        # A quoted-text class that admits the opening curly quote takes seconds here.
        start = time.monotonic()
        lint(". “" * 20000)

        self.assertLess(time.monotonic() - start, 1.0)

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
