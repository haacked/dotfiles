import io
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import redirect_stderr, redirect_stdout

sys.path.insert(0, str(Path(__file__).resolve().parent))
from claude_usage_limit import USAGE_LIMIT_PREFIXES, main, usage_limit_message  # noqa: E402


def error_result(**fields):
    return {"type": "result", "subtype": "success", "is_error": True, **fields}


class UsageLimitMessageTests(unittest.TestCase):
    def test_every_prefix_in_an_error_result_is_a_limit(self):
        for prefix in USAGE_LIMIT_PREFIXES:
            message = f"{prefix} limit · resets 3:45pm"
            with self.subTest(prefix=prefix):
                self.assertEqual(usage_limit_message(error_result(result=message)), message)

    def test_a_limit_in_the_errors_list_counts(self):
        event = error_result(
            subtype="error_during_execution",
            errors=["API request failed", "Your org is out of usage · contact your admin"],
        )
        self.assertEqual(
            usage_limit_message(event), "Your org is out of usage · contact your admin"
        )

    def test_model_credits_messages_are_limits(self):
        for message in (
            "Opus 5.5 requires usage credits. Switch to another model to continue.",
            "Sonnet requires usage credits.",
            "Mythos 1 Preview requires usage credits.",
        ):
            with self.subTest(message=message):
                self.assertEqual(usage_limit_message(error_result(result=message)), message)

    def test_model_credits_text_that_the_cli_does_not_match_is_not_a_limit(self):
        for message in (
            "Claude Opus 5.5 requires usage credits.",
            "Opus 5.5 requires usage credits",
            "Opus 5.5 · Max requires usage credits.",
        ):
            with self.subTest(message=message):
                self.assertIsNone(usage_limit_message(error_result(result=message)))

    def test_a_successful_result_that_starts_with_a_prefix_is_not_a_limit(self):
        event = error_result(is_error=False, result="You've hit your rate limit path correctly.")
        self.assertIsNone(usage_limit_message(event))

    def test_an_error_result_without_a_limit_message_is_not_a_limit(self):
        event = error_result(errors=["API Error: 500 Internal server error"], result=None)
        self.assertIsNone(usage_limit_message(event))

    def test_api_limit_error_events_are_limits(self):
        for error_type in ("rate_limit_error", "overloaded_error"):
            with self.subTest(error_type=error_type):
                event = {"type": "error", "error": {"type": error_type}}
                self.assertEqual(usage_limit_message(event), error_type)

    def test_other_error_events_are_not_limits(self):
        for event in (
            {"type": "error", "error": {"type": "invalid_request_error"}},
            {"type": "error", "error": "rate_limit_error"},
        ):
            with self.subTest(event=event):
                self.assertIsNone(usage_limit_message(event))

    def test_assistant_text_that_mentions_a_limit_is_not_a_limit(self):
        event = {
            "type": "assistant",
            "message": {"content": [{"type": "text", "text": "You've hit your session limit"}]},
        }
        self.assertIsNone(usage_limit_message(event))

    def test_values_that_are_not_events_are_not_limits(self):
        for value in (None, "You've hit your session limit", ["rate_limit_error"], 3):
            with self.subTest(value=value):
                self.assertIsNone(usage_limit_message(value))

    def test_errors_that_are_not_a_list_are_ignored(self):
        event = error_result(errors="Your org is out of usage", result="API request failed")
        self.assertIsNone(usage_limit_message(event))


class MainTests(unittest.TestCase):
    def run_main(self, lines):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False) as output:
            output.write("\n".join(lines) + "\n")
        self.addCleanup(Path(output.name).unlink)
        stdout = io.StringIO()
        with redirect_stdout(stdout):
            status = main(["claude_usage_limit.py", output.name])
        return status, stdout.getvalue()

    def test_prints_the_limit_message_and_exits_zero(self):
        status, stdout = self.run_main([
            json.dumps({"type": "system", "subtype": "init"}),
            "not json",
            json.dumps(error_result(result="You've hit your session limit · resets 3:45pm")),
        ])
        self.assertEqual((status, stdout), (0, "You've hit your session limit · resets 3:45pm\n"))

    def test_exits_zero_when_stdout_cannot_encode_the_message(self):
        with tempfile.NamedTemporaryFile("w", suffix=".jsonl", delete=False, encoding="utf-8") as output:
            output.write(json.dumps(error_result(result="You've hit your limit · resets 3pm")) + "\n")
        self.addCleanup(Path(output.name).unlink)
        result = subprocess.run(
            [sys.executable, str(Path(__file__).resolve().parent / "claude_usage_limit.py"), output.name],
            capture_output=True,
            env={**os.environ, "PYTHONIOENCODING": "ascii"},
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, b"You've hit your limit \\xb7 resets 3pm\n")

    def test_exits_one_without_a_limit(self):
        status, stdout = self.run_main([
            json.dumps({"type": "system", "subtype": "init"}),
            json.dumps({"type": "result", "subtype": "success", "is_error": False, "result": "ok"}),
        ])
        self.assertEqual((status, stdout), (1, ""))

    def test_exits_two_without_exactly_one_file(self):
        for argv in (["claude_usage_limit.py"], ["claude_usage_limit.py", "a", "b"]):
            with self.subTest(argv=argv), redirect_stderr(io.StringIO()):
                self.assertEqual(main(argv), 2)


if __name__ == "__main__":
    unittest.main()
