import importlib.util
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "review-tier.py"
RISKY_KINDS = (
    "risky-migration",
    "risky-api",
    "risky-wire-format",
    "risky-auth",
    "risky-infra",
    "risky-dependency",
    "risky-data-deletion",
)
UNCERTAIN_KINDS = (
    "uncertain-rename",
    "uncertain-copy",
    "uncertain-deleted-file",
    "uncertain-binary",
    "uncertain-mode-change",
    "uncertain-type-change",
    "uncertain-submodule",
    "uncertain-symlink",
    "uncertain-diff-failed",
)
REASON_KINDS = RISKY_KINDS + UNCERTAIN_KINDS + (
    "code-file",
    "test-lines-removed",
    "too-large",
)
REASON_PATTERN = re.compile(
    r"^(?:%s)(?:: .+)?$" % "|".join(re.escape(kind) for kind in REASON_KINDS)
)
PURPOSES = ("fix-review", "final-simplify")
SPEC = importlib.util.spec_from_file_location("review_tier", SCRIPT)
review_tier = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(review_tier)

TEST_PATHS = (
    "test/helpers.py",
    "tests/helpers.py",
    "src/__tests__/widget.js",
    "spec/widget_helper.rb",
    "testdata/sample.json",
    "src/test_widget.py",
    "src/widget_test.go",
    "src/widget.test.ts",
    "src/widget.spec.ts",
    "src/widget_spec.rb",
    "src/conftest.py",
    "ai/skills/go/scripts/tests/test_x.py",
    "tests/requirements.txt",
)
DOCS_PATHS = (
    "notes.md",
    "guide.mdx",
    "guide.rst",
    "guide.adoc",
    "README",
    "README.txt",
    "CHANGELOG",
    "LICENSE",
    "LICENSE-APACHE",
)
PROMPT_PATHS = (
    "ai/skills/x/SKILL.md",
    "ai/skills/x/references/notes.md",
    "AGENTS.md",
    "docs/CLAUDE.md",
    "ai/agents/reviewer.md",
    "commands/ship.md",
    "prompts/summary.md",
    "src/handlers/hook.md",
    "docs/skills/overview.md",
    "GEMINI.md",
    ".github/copilot-instructions.md",
    "ai/contexts/python.md",
    "ai/evals/smallest-change/rule.md",
    "ai/skills/foo/prompt.txt",
    "ai/skills/support/templates/weekly-log.txt",
    "prompts/summary.rst",
    "ai/skills/x/tests/SKILL.md",
    "tests/AGENTS.md",
)
CODE_PATHS = (
    "src/widget.py",
    "Makefile",
    "ai/skills/go/scripts/run.py",
    "src/testing.py",
    "src/tests.py",
    "docs_site/page.py",
    "docs/example.py",
    "docs/conf.py",
    "CMakeLists.txt",
    "notes.txt",
    "src/allowed_hosts.txt",
    "src/ab_test.py",
    "src/openapi_spec.yaml",
    "README.py",
)
RISKY_PATHS = (
    ("risky-migration", "docs/migrations/overview.md"),
    ("risky-migration", "tests/data_migrations/test_backfill.py"),
    ("risky-migration", "tests/Migrations/test_upper.py"),
    ("risky-migration", "tests/alembic/test_env.py"),
    ("risky-migration", "tests/fixtures/schema.sql"),
    ("risky-migration", "app/migrations/tests/test_backfill.py"),
    ("risky-api", "docs/api/usage.md"),
    ("risky-api", "guides/API/reference.md"),
    ("risky-api", "tests/openapi/test_schema.py"),
    ("risky-api", "tests/serializers/test_user.py"),
    ("risky-api", "docs/sdk/intro.md"),
    ("risky-api", "tests/fixtures/schema.graphql"),
    ("risky-wire-format", "tests/fixture.proto"),
    ("risky-wire-format", "tests/upper.PROTO"),
    ("risky-wire-format", "tests/fixture.avsc"),
    ("risky-wire-format", "tests/fixture.capnp"),
    ("risky-wire-format", "tests/fixture.thrift"),
    ("risky-wire-format", "tests/fixture.fbs"),
    ("risky-auth", "tests/auth/test_login.py"),
    ("risky-auth", "docs/permissions.md"),
    ("risky-auth", "tests/test_access_control.py"),
    ("risky-auth", "docs/access-control.md"),
    ("risky-auth", "tests/test_rbac.py"),
    ("risky-auth", "docs/csrf.md"),
    ("risky-auth", "docs/cors.md"),
    ("risky-auth", "tests/test_secrets.py"),
    ("risky-auth", "docs/credentials.md"),
    ("risky-auth", "tests/test_encrypt.py"),
    ("risky-auth", "docs/password-reset.md"),
    ("risky-auth", "docs/SECURITY.md"),
    ("risky-auth", "docs/saml.md"),
    ("risky-auth", "docs/sso.md"),
    ("risky-auth", "docs/OAuth.md"),
    ("risky-infra", "charts/README.md"),
    ("risky-infra", "helm/README.md"),
    ("risky-infra", "docs/terraform/setup.md"),
    ("risky-infra", "k8s/README.md"),
    ("risky-infra", "kubernetes/notes.md"),
    ("risky-infra", "argocd/README.md"),
    ("risky-infra", ".github/CONTRIBUTING.md"),
    ("risky-infra", "deploy/README.md"),
    ("risky-infra", "infra/README.md"),
    ("risky-infra", "tests/main.tf"),
    ("risky-infra", "tests/prod.tfvars"),
    ("risky-infra", "tests/Dockerfile.ci"),
    ("risky-infra", "tests/docker-compose.yml"),
    ("risky-infra", "tests/values.yaml"),
    ("risky-infra", "tests/values-prod.yml"),
    ("risky-dependency", "tests/requirements-dev.txt"),
    ("risky-dependency", "tests/requirements.txt"),
    ("risky-dependency", "tests/package.json"),
    ("risky-dependency", "tests/package-lock.json"),
    ("risky-dependency", "tests/pnpm-lock.yaml"),
    ("risky-dependency", "tests/yarn.lock"),
    ("risky-dependency", "tests/pyproject.toml"),
    ("risky-dependency", "tests/poetry.lock"),
    ("risky-dependency", "tests/uv.lock"),
    ("risky-dependency", "tests/Pipfile"),
    ("risky-dependency", "tests/Pipfile.lock"),
    ("risky-dependency", "tests/Cargo.toml"),
    ("risky-dependency", "tests/Cargo.lock"),
    ("risky-dependency", "tests/go.mod"),
    ("risky-dependency", "tests/go.sum"),
    ("risky-dependency", "tests/Gemfile"),
    ("risky-dependency", "tests/Gemfile.lock"),
)
NON_RISKY_LOOKALIKE_PATHS = (
    "docs/rapid/notes.md",
    "docs/api.md",
    "docs/migration-guide.md",
    "docs/charting/notes.md",
    "docs/deployment/notes.md",
    "docs/values.md",
    "docs/sql-style.md",
    "docs/protocol.md",
    "tests/test_dockerfile_parser.py",
    "tests/test_requirements.py",
    "tests/test_values.py",
)
DATA_DELETION_STATEMENTS = (
    "DELETE FROM users",
    "delete from users",
    "DROP TABLE users",
    "drop column email",
    "DROP DATABASE app",
    "DROP INDEX idx_users",
    "TRUNCATE TABLE users",
    "ALTER TABLE users ADD COLUMN age int",
    "rm -rf build",
)


def numbered_lines(count, label="line"):
    return "".join(f"{label} {number}\n" for number in range(1, count + 1))


class ReviewTierTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="go-review-tier-tests-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name).resolve()
        self.repo = self.root / "checkout with spaces"
        self.repo.mkdir()
        self.env = {
            key: value
            for key, value in os.environ.items()
            if not key.startswith("GIT_")
        }
        self.env.update(
            {
                "GIT_CONFIG_GLOBAL": os.devnull,
                "GIT_CONFIG_SYSTEM": os.devnull,
                "GIT_CONFIG_COUNT": "3",
                "GIT_CONFIG_KEY_0": "user.name",
                "GIT_CONFIG_VALUE_0": "Fixture",
                "GIT_CONFIG_KEY_1": "user.email",
                "GIT_CONFIG_VALUE_1": "fixture@example.com",
                "GIT_CONFIG_KEY_2": "commit.gpgsign",
                "GIT_CONFIG_VALUE_2": "false",
            }
        )
        self.git("init", "-q", "-b", "feature")
        self.write("seed.txt", "seed\n")
        self.commit("Initial fixture")

    def git(self, *args):
        return subprocess.run(
            ["git", "-C", str(self.repo), *args],
            env=self.env,
            check=True,
            capture_output=True,
            text=True,
        ).stdout.strip()

    def write(self, path, content):
        target = self.repo / path
        target.parent.mkdir(parents=True, exist_ok=True)
        if isinstance(content, bytes):
            target.write_bytes(content)
        else:
            target.write_text(content)

    def commit(self, message="Change"):
        self.git("add", "-A")
        self.git("commit", "-qm", message)
        return self.head()

    def head(self):
        return self.git("rev-parse", "HEAD")

    def change(self, files=None, base_files=None, removed=()):
        if base_files:
            for path, content in base_files.items():
                self.write(path, content)
            self.commit("Base")
        base = self.head()
        for path, content in (files or {}).items():
            self.write(path, content)
        for path in removed:
            (self.repo / path).unlink()
        self.commit("Change under review")
        return base

    def invoke(self, *args):
        return subprocess.run(
            [sys.executable, str(SCRIPT), *args],
            cwd=self.repo,
            env=self.env,
            capture_output=True,
            text=True,
            timeout=30,
        )

    def tier(self, purpose, base, head=None):
        args = ["--purpose", purpose, "--base", base]
        if head is not None:
            args += ["--head", head]
        completed = self.invoke(*args)
        self.assertEqual(completed.returncode, 0, completed.stderr)
        result = json.loads(completed.stdout)
        self.assertValidSchema(result)
        return result

    def assertValidSchema(self, result):
        self.assertEqual(
            set(result), {"purpose", "base", "head", "tier", "reasons", "stats"}
        )
        self.assertIn(result["tier"], {"skip", "full"})
        self.assertIsInstance(result["reasons"], list)
        for reason in result["reasons"]:
            self.assertIsInstance(reason, str)
            self.assertRegex(reason, REASON_PATTERN)
        self.assertEqual(set(result["stats"]), {"lines", "files"})
        self.assertIsInstance(result["stats"]["lines"], int)
        self.assertIsInstance(result["stats"]["files"], int)

    def assertHasReason(self, result, kind, detail=None):
        matches = [
            reason
            for reason in result["reasons"]
            if reason.startswith(kind) and (detail is None or detail in reason)
        ]
        self.assertTrue(matches, f"no {kind} reason with {detail!r} in {result}")

    def assertLacksReason(self, result, kind):
        self.assertFalse(
            [reason for reason in result["reasons"] if reason.startswith(kind)],
            f"unexpected {kind} reason in {result}",
        )

    def assertTier(self, result, tier):
        self.assertEqual(result["tier"], tier, result)

    def make_executable(self, path, message):
        os.chmod(self.repo / path, 0o755)
        self.git("add", "-A")
        self.git("update-index", "--chmod=+x", path)
        self.git("commit", "-qm", message)

    def add_one(self, path, content=None, purpose="fix-review"):
        base = self.change({path: numbered_lines(3) if content is None else content})
        return self.tier(purpose, base)

    def test_small_migration_change_requires_full_fix_review(self):
        base = self.change({"app/migrations/0002_add_column.py": numbered_lines(3)})

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "risky-migration")

    def test_new_test_under_migrations_requires_full_fix_review_without_code_file(self):
        base = self.change({"app/migrations/tests/test_backfill.py": numbered_lines(3)})

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "risky-migration")
        self.assertLacksReason(result, "code-file")

    def test_rename_of_twelve_unchanged_files_requires_full_for_both_purposes(self):
        originals = {
            f"src/module_{number}.py": numbered_lines(5, f"module {number}")
            for number in range(12)
        }
        for path, content in originals.items():
            self.write(path, content)
        self.commit("Base")
        base = self.head()
        (self.repo / "lib").mkdir()
        for number in range(12):
            self.git("mv", f"src/module_{number}.py", f"lib/module_{number}.py")
        self.commit("Move modules")

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-rename")
                self.assertEqual(result["stats"], {"lines": 0, "files": 12})

    def test_rename_into_risky_directory_reports_the_risk(self):
        base = self.change(
            {"docs/migrations/notes.md": numbered_lines(5, "note")},
            base_files={"docs/notes.md": numbered_lines(5, "note")},
            removed=("docs/notes.md",),
        )

        result = self.tier("fix-review", base)

        self.assertHasReason(result, "uncertain-rename")
        self.assertHasReason(result, "risky-migration")

    def test_copy_of_modified_file_requires_full_for_both_purposes(self):
        original = numbered_lines(30, "original")
        base = self.change(
            {"src/orig.py": original + "extra\n", "lib/copy.py": original},
            base_files={"src/orig.py": original},
        )

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-copy")

    def test_deleted_lines_in_code_file_require_full_fix_review(self):
        base = self.change(
            {"src/app.py": numbered_lines(7)},
            base_files={"src/app.py": numbered_lines(10)},
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "code-file", "src/app.py")

    def test_deleted_lines_in_test_file_require_full_fix_review(self):
        base = self.change(
            {"tests/test_app.py": numbered_lines(7)},
            base_files={"tests/test_app.py": numbered_lines(10)},
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "test-lines-removed")

    def test_deleted_lines_in_docs_file_skip_fix_review(self):
        base = self.change(
            {"docs/guide.md": numbered_lines(7)},
            base_files={"docs/guide.md": numbered_lines(10)},
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")

    def test_five_deleted_lines_in_code_file_skip_final_simplify(self):
        base = self.change(
            {"src/app.py": numbered_lines(5)},
            base_files={"src/app.py": numbered_lines(10)},
        )

        result = self.tier("final-simplify", base)

        self.assertTier(result, "skip")

    def test_test_file_with_equal_added_and_removed_lines_skips_fix_review(self):
        base = self.change(
            {"tests/test_app.py": numbered_lines(3, "new") + numbered_lines(7, "old")},
            base_files={"tests/test_app.py": numbered_lines(10, "old")},
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")
        self.assertLacksReason(result, "test-lines-removed")

    def test_test_lines_removed_is_judged_per_file_not_over_the_whole_diff(self):
        base = self.change(
            {
                "tests/test_shrunk.py": numbered_lines(7),
                "tests/test_grown.py": numbered_lines(20),
            },
            base_files={"tests/test_shrunk.py": numbered_lines(10)},
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "test-lines-removed")

    def test_removed_test_lines_do_not_affect_final_simplify(self):
        base = self.change(
            {"tests/test_app.py": numbered_lines(5)},
            base_files={"tests/test_app.py": numbered_lines(10)},
        )

        result = self.tier("final-simplify", base)

        self.assertTier(result, "skip")

    def test_modified_line_counts_as_one_added_and_one_removed(self):
        base = self.change(
            {"src/app.py": "changed\n" + numbered_lines(4)},
            base_files={"src/app.py": "original\n" + numbered_lines(4)},
        )

        result = self.tier("fix-review", base)

        self.assertEqual(result["stats"], {"lines": 2, "files": 1})

    def test_deleted_file_requires_full_for_both_purposes(self):
        base = self.change(
            base_files={"docs/old.md": numbered_lines(3)}, removed=("docs/old.md",)
        )

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-deleted-file")

    def test_deleted_migration_file_reports_the_risk(self):
        base = self.change(
            base_files={"app/migrations/0001_initial.py": numbered_lines(3)},
            removed=("app/migrations/0001_initial.py",),
        )

        result = self.tier("fix-review", base)

        self.assertHasReason(result, "risky-migration")

    def test_binary_file_requires_full_for_both_purposes(self):
        base = self.change({"docs/logo.png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR"})

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-binary")

    def test_binary_file_contributes_no_lines(self):
        base = self.change(
            {
                "docs/logo.png": b"\x89PNG\r\n\x1a\n\x00\x00\x00\x0dIHDR",
                "tests/test_logo.py": numbered_lines(4),
            }
        )

        result = self.tier("fix-review", base)

        self.assertEqual(result["stats"], {"lines": 4, "files": 2})

    def test_mode_change_only_requires_full_for_both_purposes(self):
        self.write("docs/example.sh", numbered_lines(3))
        self.commit("Base")
        base = self.head()
        self.make_executable("docs/example.sh", "Make example executable")

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-mode-change")

    def test_mode_change_with_content_change_requires_full(self):
        self.write("docs/example.sh", numbered_lines(3))
        self.commit("Base")
        base = self.head()
        self.write("docs/example.sh", numbered_lines(4))
        self.make_executable("docs/example.sh", "Edit example and make it executable")

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "uncertain-mode-change")

    def test_new_executable_file_is_not_a_mode_change(self):
        base = self.head()
        self.write("tests/run_fixture.sh", numbered_lines(3))
        self.make_executable("tests/run_fixture.sh", "Add executable fixture")

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")
        self.assertLacksReason(result, "uncertain-mode-change")

    def test_added_symlink_requires_full_for_both_purposes(self):
        self.write("docs/guide.md", numbered_lines(3))
        self.commit("Base")
        base = self.head()
        os.symlink("guide.md", self.repo / "docs/link.md")
        self.commit("Add symlink")

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-symlink")

    def test_regular_file_replaced_by_symlink_requires_full_with_type_change(self):
        self.write("docs/guide.md", numbered_lines(3))
        self.write("docs/target.md", numbered_lines(3, "target"))
        self.commit("Base")
        base = self.head()
        (self.repo / "docs/target.md").unlink()
        os.symlink("guide.md", self.repo / "docs/target.md")
        self.commit("Replace file with symlink")

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-type-change")

    def test_added_submodule_requires_full_for_both_purposes(self):
        base = self.head()
        self.git("update-index", "--add", "--cacheinfo", f"160000,{base},vendor/lib")
        self.git("commit", "-qm", "Add submodule")

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, base)

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-submodule")

    def test_small_readme_change_skips_fix_review(self):
        base = self.change({"README.md": numbered_lines(3)})

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")

    def test_new_test_file_of_100_lines_skips_fix_review(self):
        base = self.change({"tests/test_big.py": numbered_lines(100)})

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")

    def test_new_test_file_of_101_lines_requires_full_fix_review(self):
        base = self.change({"tests/test_big.py": numbered_lines(101)})

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "too-large")

    def test_fix_review_size_threshold_sums_lines_across_files(self):
        base = self.change(
            {
                "tests/test_one.py": numbered_lines(50),
                "docs/guide.md": numbered_lines(51),
            }
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "too-large")

    def test_test_file_adding_delete_from_requires_full_fix_review(self):
        base = self.change({"tests/test_cleanup.py": 'sql = "DELETE FROM users"\n'})

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "risky-data-deletion")

    def test_added_data_deletion_line_that_starts_with_plus_plus_is_risky(self):
        base = self.change({"tests/test_cleanup.py": "++ DROP TABLE users;\n"})

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "risky-data-deletion")

    def test_external_diff_driver_does_not_hide_added_data_deletion(self):
        base = self.change({"tests/test_cleanup.py": 'sql = "DELETE FROM users"\n'})
        self.env["GIT_EXTERNAL_DIFF"] = "true"

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "risky-data-deletion")

    def test_removed_data_deletion_statement_is_not_risky(self):
        base = self.change(
            {"tests/test_cleanup.py": "SELECT 1\nkeep\n"},
            base_files={"tests/test_cleanup.py": "DELETE FROM users\nkeep\n"},
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")
        self.assertLacksReason(result, "risky-data-deletion")

    def test_data_deletion_words_in_a_file_name_are_not_risky(self):
        result = self.add_one("tests/test_drop table notes.py")

        self.assertTier(result, "skip")
        self.assertLacksReason(result, "risky-data-deletion")

    def test_final_simplify_skips_20_changed_lines_of_code(self):
        base = self.change({"src/app.py": numbered_lines(20)})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "skip")

    def test_final_simplify_requires_full_for_21_changed_lines_of_code(self):
        base = self.change({"src/app.py": numbered_lines(21)})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "too-large")

    def test_final_simplify_size_threshold_counts_docs_lines_next_to_code(self):
        base = self.change(
            {"src/app.py": numbered_lines(1), "docs/guide.md": numbered_lines(20)}
        )

        result = self.tier("final-simplify", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "too-large")

    def test_final_simplify_skips_large_docs_only_change(self):
        base = self.change(
            {"docs/guide.md": numbered_lines(150), "README.md": numbered_lines(150)}
        )

        result = self.tier("final-simplify", base)

        self.assertTier(result, "skip")

    def test_final_simplify_does_not_treat_large_test_change_as_docs(self):
        base = self.change({"tests/test_big.py": numbered_lines(30)})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "too-large")

    def test_final_simplify_does_not_treat_large_prompt_change_as_docs(self):
        base = self.change({"ai/skills/x/SKILL.md": numbered_lines(30)})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "too-large")

    def test_final_simplify_skips_small_migration_change(self):
        base = self.change({"app/migrations/0002_add_column.py": numbered_lines(3)})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "skip")

    def test_final_simplify_skips_small_data_deletion_change(self):
        base = self.change({"tests/test_cleanup.py": 'sql = "DROP TABLE users"\n'})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "skip")

    def test_final_simplify_omits_risky_reasons_from_full_result(self):
        base = self.change({"app/migrations/0003_big.py": numbered_lines(25)})

        result = self.tier("final-simplify", base)

        self.assertTier(result, "full")
        for kind in RISKY_KINDS:
            self.assertLacksReason(result, kind)

    def test_final_simplify_requires_full_for_uncertain_docs_change(self):
        base = self.change(
            {"docs/guide.md": numbered_lines(150)},
            base_files={"docs/old.md": numbered_lines(3)},
            removed=("docs/old.md",),
        )

        result = self.tier("final-simplify", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "uncertain-deleted-file")

    def test_fix_review_lists_every_reason_that_applies(self):
        base = self.change(
            {
                "app/migrations/0003_big.py": numbered_lines(101),
                "tests/test_old.py": numbered_lines(1),
            },
            base_files={
                "docs/old.md": numbered_lines(3),
                "tests/test_old.py": numbered_lines(5),
            },
            removed=("docs/old.md",),
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        for kind in (
            "risky-migration",
            "uncertain-deleted-file",
            "code-file",
            "test-lines-removed",
            "too-large",
        ):
            with self.subTest(kind=kind):
                self.assertHasReason(result, kind)

    def test_base_equal_to_head_skips_both_purposes(self):
        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, "HEAD")

                self.assertTier(result, "skip")
                self.assertEqual(result["reasons"], [])
                self.assertEqual(result["stats"], {"lines": 0, "files": 0})

    def test_empty_commit_range_skips(self):
        base = self.head()
        self.git("commit", "--allow-empty", "-qm", "Empty")

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")

    def test_unresolvable_base_exits_zero_with_full_and_diff_failed(self):
        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, "deadbeef")

                self.assertTier(result, "full")
                self.assertHasReason(result, "uncertain-diff-failed")
                self.assertEqual(
                    (result["purpose"], result["base"], result["head"]),
                    (purpose, "deadbeef", "HEAD"),
                )

    def test_unresolvable_head_exits_zero_with_full_and_diff_failed(self):
        result = self.tier("fix-review", "HEAD", "deadbeef")

        self.assertTier(result, "full")
        self.assertHasReason(result, "uncertain-diff-failed")

    def test_multi_commit_range_counts_changes_from_every_commit(self):
        base = self.head()
        self.write("src/one.py", numbered_lines(2))
        self.commit("First")
        self.write("tests/test_two.py", numbered_lines(3))
        self.commit("Second")

        result = self.tier("fix-review", base)

        self.assertEqual(result["stats"], {"lines": 5, "files": 2})
        self.assertHasReason(result, "code-file", "src/one.py")

    def test_explicit_head_excludes_later_commits(self):
        base = self.head()
        self.write("tests/test_a.py", numbered_lines(3))
        head = self.commit("Test")
        self.write("src/late.py", numbered_lines(3))
        self.commit("Later code")

        result = self.tier("fix-review", base, head)

        self.assertTier(result, "skip")
        self.assertEqual(result["stats"], {"lines": 3, "files": 1})

    def test_diff_compares_trees_directly_rather_than_from_merge_base(self):
        self.git("checkout", "-qb", "side")
        self.write("docs/side.md", numbered_lines(3, "side"))
        side = self.commit("Side change")
        self.git("checkout", "-q", "feature")
        self.write("docs/main.md", numbered_lines(3, "feature"))
        self.commit("Feature change")

        result = self.tier("fix-review", side)

        self.assertTier(result, "full")
        self.assertHasReason(result, "uncertain-deleted-file")

    def test_mixed_docs_and_tests_of_60_lines_skip_fix_review(self):
        base = self.change(
            {"docs/guide.md": numbered_lines(30), "tests/test_app.py": numbered_lines(30)}
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "skip")

    def test_mixed_change_with_one_code_file_names_only_that_file(self):
        base = self.change(
            {
                "docs/guide.md": numbered_lines(30),
                "tests/test_app.py": numbered_lines(29),
                "src/app.py": numbered_lines(1),
            }
        )

        result = self.tier("fix-review", base)

        self.assertTier(result, "full")
        self.assertHasReason(result, "code-file", "src/app.py")
        code_reasons = [r for r in result["reasons"] if r.startswith("code-file")]
        self.assertFalse(
            [r for r in code_reasons if "docs/guide.md" in r or "tests/test_app.py" in r],
            result,
        )

    def test_output_echoes_purpose_base_and_given_head(self):
        self.write("docs/guide.md", numbered_lines(3))
        self.commit("Docs")

        for purpose in PURPOSES:
            with self.subTest(purpose=purpose):
                result = self.tier(purpose, "HEAD~1", "HEAD")

                self.assertEqual(
                    (result["purpose"], result["base"], result["head"]),
                    (purpose, "HEAD~1", "HEAD"),
                )

    def test_output_head_defaults_to_head(self):
        self.write("docs/guide.md", numbered_lines(3))
        self.commit("Docs")

        result = self.tier("fix-review", "HEAD~1")

        self.assertEqual(result["head"], "HEAD")

    def test_output_counts_a_rename_as_one_file(self):
        base = self.change(
            {"docs/new-name.md": numbered_lines(10, "same")},
            base_files={"docs/old-name.md": numbered_lines(10, "same")},
            removed=("docs/old-name.md",),
        )

        result = self.tier("fix-review", base)

        self.assertEqual(result["stats"]["files"], 1)

    def test_usage_errors_exit_2(self):
        cases = {
            "missing purpose": ("--base", "HEAD"),
            "unknown purpose": ("--purpose", "review", "--base", "HEAD"),
            "missing base": ("--purpose", "fix-review"),
        }
        for name, args in cases.items():
            with self.subTest(case=name):
                completed = self.invoke(*args)

                self.assertEqual(completed.returncode, 2, completed.stderr)
                self.assertIn("usage:", completed.stderr)


class PathRuleTests(unittest.TestCase):
    def assert_class(self, paths, expected):
        for path in paths:
            with self.subTest(path=path):
                self.assertEqual(review_tier.file_class(path), expected)

    def test_prompt_markdown_is_code(self):
        self.assert_class(PROMPT_PATHS, "code")

    def test_test_paths_are_tests(self):
        self.assert_class(TEST_PATHS, "test")

    def test_docs_paths_are_docs(self):
        self.assert_class(DOCS_PATHS, "docs")

    def test_code_paths_are_code(self):
        self.assert_class(CODE_PATHS, "code")

    def test_risky_docs_and_test_paths_report_their_risk(self):
        for kind, path in RISKY_PATHS:
            with self.subTest(kind=kind, path=path):
                self.assertNotEqual(review_tier.file_class(path), "code")
                risks = review_tier.path_risks(path)
                self.assertTrue(any(risk.startswith(kind) for risk in risks), risks)

    def test_risky_lookalike_paths_report_no_risk(self):
        for path in NON_RISKY_LOOKALIKE_PATHS:
            with self.subTest(path=path):
                self.assertNotEqual(review_tier.file_class(path), "code")
                self.assertEqual(review_tier.path_risks(path), [])

    def test_data_deletion_statements_match(self):
        for statement in DATA_DELETION_STATEMENTS:
            with self.subTest(statement=statement):
                self.assertTrue(
                    review_tier.DATA_DELETION.search(f'command = "{statement}"')
                )


if __name__ == "__main__":
    unittest.main()
