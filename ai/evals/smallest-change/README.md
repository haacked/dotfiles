# Smallest complete change eval

An eval-only plugin that measures what the Smallest complete change rule in `ai/skills/go/SKILL.md` does to a plain implementation task. It never runs /go, so a run opens no PR and requests no review.

## What each arm loads

- **With:** this plugin. Its only content is a `SessionStart` hook that prints `rule.md` into the session context. The plugin has no skill, so the rule is in context on every run, and the result does not depend on whether the model chooses to invoke a skill. /go gives its implementers this rule together with the Judgment calls rule, but this arm gets this rule alone, so the "easy-to-reverse call" that item 1 mentions has no definition here.
- **Without:** the baseline arm that `--ablation with-without` adds. It runs the same prompt in the same scaffolded workspace with no plugin loaded, so the rule is the only difference between the arms.

`rule.md` is the rule from `ai/skills/go/SKILL.md` without its first sentence, which tells /go which agents get the rule. `ai/tests/test-eval-rule-sync.sh` fails when the two copies differ.

## Cases

Each case is a small Python repo where an over-built answer is tempting.

| Case | Task | What over-building looks like |
| --- | --- | --- |
| `csv-export` | Add `write_csv(rows, path)` | Hand-rolled quoting, or delimiter and encoding options nobody asked for |
| `permalink-reuse` | Add `Post.permalink` | A new slug function when `blog/text.py` already has `slugify` |
| `shared-bug-fix` | Fix a thousands-separator bug reported against the cart | Patching only the cart, when the refund path calls the same parser |

`shared-bug-fix` guards the other direction: the rule must shrink the solution, not the scope, so a caller-only patch fails its hidden tests.

## How grading works

`claude plugin eval` has no grader that runs a command, so the grading runs inside the workspace. `evals/scaffold.sh` copies the case's `repo/` into the workspace and commits it. It also puts the hidden tests and `grade.py` in `.eval/` and writes a `Stop` hook to `.claude/settings.json`. When the session ends, the hook runs `grade.py`, which writes `eval-result.txt`. The case's regex graders read that file:

- `hidden_tests: pass` when the hidden tests and the repo's own tests pass. This grader has weight 2.
- `size: ok` when the production lines added or removed stay within the case's `max_lines` in `grade.json`. Lines under `tests/` and in `test_*` files do not count.
- `dependencies: unchanged` when no dependency file (`pyproject.toml`, `requirements*.txt`, `setup.py`, `setup.cfg`, `Pipfile`) changed.
- `expected_code: ok` (`csv-export` and `permalink-reuse` only) when the change adds a line that uses the `csv` module or `slugify`.

`eval-result.txt` also records the exact line count and the changed files, which `--keep-temp` leaves on disk for a closer look.

## Running it

Each run is a full Claude session, so the full suite (3 cases × 3 runs × 2 arms) is 18 sessions. Start with one case and one run:

```bash
claude plugin eval ai/evals/smallest-change --scaffold --allow-tools Edit Write Bash --case csv-export --runs 1 --max-cost-usd 1 --no-publish
```

`--scaffold` is required, because without it the workspace is empty. `--allow-tools` grants the tools the cases list. `--max-cost-usd 0` loads and plans every case without starting a run, which checks that the cases parse.

The hidden tests sit in the workspace's `.eval/` folder. Git ignores that folder, but the agent can still find and read it in either arm.

The graders depend on the eval run loading the workspace's `.claude/settings.json`, which the eval docs do not cover. If every grader fails in both arms and `--keep-temp` shows no `eval-result.txt`, the `Stop` hook did not run.
