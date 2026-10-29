# Smallest complete change eval

An eval-only plugin that measures what the Smallest complete change rule in `ai/skills/go/SKILL.md` does to a plain implementation task. It never runs /go, so a run opens no PR and requests no review.

## What each arm loads

- **With:** this plugin. A `SessionStart` hook prints `rule.md` into the session context, and a `Stop` hook grades the workspace. The plugin has no skill, so the rule is in context on every run, and the result does not depend on whether the model chooses to invoke a skill. /go gives its implementers this rule together with the Judgment calls rule, but this arm gets this rule alone, so the "easy-to-reverse call" that item 1 mentions has no definition here.
- **Without:** a baseline plugin that `run.sh` builds under `results/<timestamp>/baseline-plugin/` for each run. It holds a copy of this plugin's `evals` and this plugin's hooks minus the `SessionStart` hook, so both arms run the same cases and grade the same way. The eval refuses an `evals` folder that links outside its plugin, which is why the baseline holds a copy.

The eval's own `--ablation with-without` does not work here. Its baseline arm loads no plugin at all, including plugins that a case lists, and the eval ignores the workspace's `.claude/settings.json`. That leaves no way to grade the baseline arm, so `run.sh` runs each plugin as a single-arm eval instead.

`rule.md` is a copy of the rule from `ai/skills/go/SKILL.md`. `ai/tests/test-eval-rule-sync.sh` fails when the two copies differ.

## Cases

Each case is a small Python repo where an over-built answer is tempting.

| Case | Task | What over-building looks like |
| --- | --- | --- |
| `csv-export` | Add `write_csv(rows, path)` | Hand-rolled quoting, or delimiter and encoding options nobody asked for |
| `permalink-reuse` | Add `Post.permalink` | A new slug function when `blog/text.py` already has `slugify` |
| `shared-bug-fix` | Fix a thousands-separator bug reported against the cart | Patching only the cart, when the refund path calls the same parser |

`shared-bug-fix` guards the other direction: the rule must shrink the solution, not the scope, so a caller-only patch fails its hidden tests.

## How grading works

`claude plugin eval` has no grader that runs a command, so a `Stop` hook does the grading. `evals/scaffold.sh` copies the case's `repo/` into the workspace and commits it. It also puts the hidden tests, `grade.py`, and a `grade.sh` that runs it in `.eval/`. When the session ends, both plugins' `Stop` hook runs `grade.sh`, which writes `eval-result.txt`. The case's regex graders read that file:

- `hidden_tests: pass` when the hidden tests and the repo's own tests pass. This grader has weight 2.
- `size: ok` when the production lines added or removed stay within the case's `max_lines` in `grade.json`. Lines under `tests/` and in `test_*` files do not count.
- `dependencies: unchanged` when no dependency file (`pyproject.toml`, `requirements*.txt`, `setup.py`, `setup.cfg`, `Pipfile`) changed.
- `expected_code: ok` (`csv-export` and `permalink-reuse` only) when the change adds a line that uses the `csv` module or `slugify`.

`eval-result.txt` also records the exact line count and the changed files. `--keep-temp` leaves each workspace on disk, sealed, and the eval prints how to open it.

## Running it

Each run is a full Claude session, and `run.sh` runs every case in both arms, so the full suite (3 cases × 3 runs × 2 arms) is 18 sessions. Start with one case and one run per arm:

```bash
ai/evals/smallest-change/run.sh --case csv-export --runs 1 --max-cost-usd 1
```

`run.sh` passes its arguments to both `claude plugin eval` calls, so `--max-cost-usd` caps each arm separately. It writes both results under `results/<timestamp>/` and then prints each grader's pass count in each arm with `compare.py`.

The eval refuses to grant Bash when `~/.ssh` holds a symbolic link, because its sandbox cannot keep the link's target out of reach. On such a machine, add `--disallow-tools Bash`. The agent then cannot run tests in either arm, but grading still works, because the `Stop` hook does not need the agent's Bash.

`--max-cost-usd 0` loads and plans every case without starting a run, which checks that the cases parse.

The hidden tests sit in the workspace's `.eval/` folder. Git ignores that folder, but the agent can still find and read it in either arm.
