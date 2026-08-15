---
name: go
description: Plan, implement, and review a task end-to-end — review-code + ReviewHog in parallel, every review addressed, open items explained. Idempotent — re-running reports where the pipeline stands and resumes from the first incomplete step.
argument-hint: "<task description> [--skip-planner] [--skip-reviewhog] [--plan-file <path>]"
---

# /go

End-to-end orchestrator: plan → implement → simplify → commit → open draft PR → request a ReviewHog round → run `review-code --fix` while ReviewHog works → address every review comment → explain the open items that need the user's judgment.

The pipeline is idempotent. `.notes/go-state.md` tracks progress, so re-running `/go` reports where the pipeline stands and resumes from the first incomplete or stale step. On a branch `/go` never drove, it infers position from the session conversation, working tree, branch commits, and PR, then proceeds as if it had been running all along.

The review phase delegates to skills that fan out their own subagents (`review-code`'s reviewer fleet, `wait-for-pr-reviews` chaining `address-pr-reviews`), so the main context carries orchestration, planning, and the initial implementation.

## Arguments

- `<task description>` — what to build/fix. Omit to resume: `/go` detects the branch's position and continues from there (see Step 2).
- `--skip-planner` — skip the `implementation-planner` sub-agent; implement directly from the description.
- `--skip-reviewhog` — don't request or wait on a ReviewHog round; `review-code` and the explain-open wrap-up still run. Applied automatically when the `reviewhog` label can't be added (the repo doesn't have it).
- `--plan-file <path>` — use an already-approved plan file directly (e.g. one written by Plan Mode) instead of looking up or generating one. Implies skipping the planner.

## State file

`.notes/go-state.md` records pipeline progress for the branch. Every step appends its entry the moment it completes, so an interrupted run resumes exactly where it stopped:

```markdown
# /go state
branch: haacked/add-dark-mode-toggle
slug: add-dark-mode-toggle
plan: ~/dev/ai/plans/haacked/dotfiles/add-dark-mode-toggle.md

- implement: done
- simplify-commit: a1b2c3d
- pr: 123
- reviewhog-requested: done
- review-code: e4f5a6b
- reviews-addressed: f7a8b9c
```

Step values are `git rev-parse --short HEAD` captured when the step finished (`done` for `implement`, the PR number for `pr`, `done` or `skipped` for `reviewhog-requested`). If `branch:` doesn't match the current branch, ignore the file and re-infer per Step 2.

## Steps

### Step 1: Parse arguments

Extract from `$ARGUMENTS`:

- `SKIP_PLANNER` — boolean, true if `--skip-planner` is present.
- `SKIP_REVIEWHOG` — boolean, true if `--skip-reviewhog` is present.
- `PLAN_FILE` — the path following `--plan-file`, if present.
- `TASK` — everything else, joined with spaces.
- `SLUG` — short kebab-case identifier derived from `TASK` (e.g. "add dark mode toggle" → "add-dark-mode-toggle"). Used in commit messages and planner descriptions. If `TASK` is empty, `SLUG` comes from the state file, the plan file's first heading, or the branch name — resolved in Step 2.

### Step 2: Determine position

Gather the facts in one round trip:

```bash
git check-ignore -q .notes 2>/dev/null || echo '.notes/' >> "$(git rev-parse --git-common-dir)/info/exclude"
git status --porcelain
git log @{u}..HEAD --oneline 2>/dev/null | head -20
git rev-parse --short HEAD
cat .notes/go-state.md 2>/dev/null
gh pr list --head "$(git branch --show-current)" --json number,state,isDraft,labels --jq '.[0] // empty'
```

**Fresh cycle or resume?** If `TASK` or `PLAN_FILE` is given and the state file is missing or names a different slug, this is a new cycle: write a fresh `.notes/go-state.md` header (branch, slug, plan pending), apply the work branch guard below, and run everything from Step 3. If `TASK` matches the state file's slug, or no `TASK` was given, resume.

**Resuming without a state file** (a session `/go` didn't drive): infer entries from the world and write them to a new state file:

- Commits ahead of upstream/base, or a dirty tree → an implementation exists. Derive `SLUG` from the branch name (minus any `owner/` prefix), or from the latest commit subject when the branch name carries no signal (default branch, detached HEAD).
- Judge whether that implementation is finished. The original ask is usually in the session conversation — compare it against what the diff delivers — and the diff itself signals incompleteness: TODO/FIXME markers it introduces, stubbed or never-wired functions, failures mentioned in the session but never fixed. If work remains, write a brief (goal from the original ask, what's already in place, what remains, definition of done), record `plan: brief`, and leave `implement` unrecorded so the resume point lands on Step 4 to finish the job — and skip the test-gap dispatch below, since Step 4 dispatches its own tester with that brief. If the work looks complete, or there's no evidence either way, record `implement: done` — simplify and the review loops take it from there.
- If `implement` was recorded done and the tree is clean with branch commits → also `simplify-commit: <HEAD sha>`.
- Open PR on the branch → `pr: <number>`.
- Review steps are never inferred — leave them pending. Re-reviewing already-reviewed work is cheap; skipping an un-run review isn't.
- If the adopted diff (dirty files plus commits since the merge-base with the default branch) touches testable code but no test files, dispatch `unit-test-writer` in the background now, prompted with the diff: write tests for the changed behavior, match existing test conventions, report which fail. Note the gap in the position report. Fold the results in at the next commit — resuming at Step 5, collect after `/simplify` so the tests ride the same commit; resuming later, collect before Step 7 starts, reconcile guessed names against the real code, run the suite, and commit via `Skill("commit", args: "--force Add tests for $SLUG")`. Skip the dispatch for diffs with no testable behavior (docs, config).
- Nothing to resume (clean tree, no branch commits, no PR, no `TASK`) → stop and ask the user what to build.

**Work branch guard.** If HEAD is detached or the current branch is the repo's default branch, create and switch to `haacked/$SLUG` before anything commits — uncommitted work carries over with the checkout. If the default branch also had local commits its upstream lacks, they're on the new branch now; point the default branch back at its upstream (`git branch -f main origin/main`) so the work lives only on the feature branch, and say so in the position report. A branch created here has no PR yet — leave `pr` pending regardless of what the earlier lookup returned.

**Compute the resume point.** If `reviews-addressed` equals current HEAD (or `review-code` does and ReviewHog was skipped — `SKIP_REVIEWHOG` or `reviewhog-requested: skipped`), the pipeline is complete — report the all-done checklist and stop. Otherwise the resume point is the first step in pipeline order that is missing from the state file or stale:

| Step | Done when | Stale when |
| --- | --- | --- |
| plan | `plan:` recorded, or `implement` is done | never |
| implement | entry present | never |
| simplify-commit | sha recorded and the tree is clean | tree is dirty — new work needs simplify + commit |
| pr | number recorded, or an open PR exists on the branch | PR closed or merged → report it and stop; this branch is finished |
| reviewhog-requested | `done`/`skipped` recorded, or the `reviewhog` label is already on the PR | never — the label persists; new rounds are ReviewHog's own behavior |
| review-code | sha equals current HEAD | HEAD has moved since the last pass |
| reviews-addressed | sha equals current HEAD (not required when ReviewHog was skipped) | HEAD has moved |

Report the position to the user as a short checklist before continuing — ✓ done (with its sha or PR number), → resume point (with why it's pending or stale), · not yet run. Then run linearly from the resume point; every later step executes as normal.

### Step 3: Plan

If `PLAN_FILE` was supplied via `--plan-file`, skip the planner and the existing-plan search below entirely: read the plan file with the Read tool, and derive `SLUG` from its first `#` heading (kebab-cased) if `TASK` wasn't otherwise provided — fall back to slugifying `TASK` or the current branch name if the plan has no clear heading. Still compute `plan_dir` using the snippet below, then copy the plan file to `$plan_dir/$SLUG.md` (creating the directory if needed) so it participates in the same archival convention as planner-authored plans and a later `/go` re-invocation on this branch still finds it — unless `plan_dir` comes back empty (unrecognized repo), in which case skip the copy and just proceed with the original `PLAN_FILE` path. Tell the user which plan you're using, record it, and go to Step 4.

If `SKIP_PLANNER` is true, skip the planner but still write a brief: one paragraph covering goal, files in scope, definition of done, and out of scope. Without it, every subagent spawned later interprets the raw task description independently and they diverge. Use the brief as the spec wherever later steps reference the plan, record `plan: brief`, then go to Step 4.

First, check whether a plan already exists for this work. Compute the plan directory based on `~/CLAUDE.md` conventions:

```bash
repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null || echo "")
branch=$(git branch --show-current)
case "$repo" in
  PostHog/*) plan_dir="$HOME/dev/haacked/notes/PostHog/repositories/${repo#PostHog/}/plans" ;;
  */*)       plan_dir="$HOME/dev/ai/plans/$repo" ;;
  *)         plan_dir="" ;;
esac
```

If `$plan_dir` is set, look for an existing plan in this preference order:

1. `$plan_dir/$SLUG.md`
2. `$plan_dir/${branch##*/}.md` (branch name minus any `owner/` prefix)
3. If the directory contains exactly one `.md` file, use it

If a plan was found, read its first 100 lines with the Read tool (read specific later sections only when a step needs them), briefly tell the user which plan you're using, record it, and skip to Step 4.

Otherwise spawn the planner as a sub-agent so its research stays out of the main context:

```text
Agent tool with:
  subagent_type: implementation-planner
  description: "Plan: $SLUG"
  prompt: <TASK> plus any relevant context from this conversation
```

The planner writes a plan file per its own contract.

When the plan is settled — found, copied, generated, or a brief — record `plan: <path>` (or `plan: brief`) in the state file header.

### Step 4: Implement

First, dispatch the test writer in the background so tests are designed from the spec, not the implementation:

```text
Agent tool with:
  subagent_type: unit-test-writer
  description: "Tests: $SLUG"
  run_in_background: true
  prompt: the plan file contents (or the Step 3 brief) — and nothing else.
    Instruct it to write tests for the behavior the spec defines, match
    existing test conventions, and report which tests fail. Failures are
    expected: the implementation doesn't exist yet.
```

Tests written with the implementation in view tend to mirror it instead of testing the spec, so do not include any implementation details in the prompt. Skip the dispatch if the task has no testable behavior (docs, config, a refactor already covered by existing tests).

Then implement the change in the current context. Follow the plan file if one exists, otherwise work directly from `TASK`. This step is conversational — check in with the user on judgment calls.

**Preserve context aggressively.** The review phase in Steps 7–9 delegates its heavy lifting to skills and subagents, but Step 4 stays in main context through the rest of the run. Every file read and search compounds. Push expensive reads into subagents that return summaries instead of raw content:

- **Codebase exploration** (anything that would take more than ~3 greps/reads to answer): spawn `Explore`. Ask for the specific answer, not a file dump — e.g. "where is auth middleware registered and what's its call signature?" rather than "show me the auth code".
- **Writing tests**: already running in the background from the dispatch above. Only spawn another `unit-test-writer` for behavior discovered during implementation that the spec didn't cover. Don't read the test file into main context first — the subagent will.
- **Stuck after two failed fix attempts**: spawn `bug-root-cause-analyzer` rather than continuing to debug in main context.
- **Reading large generated files, lockfiles, fixtures, or logs**: spawn `general-purpose` with a narrow question. Never `Read` a file >500 lines into main context unless you actually need to edit it.

The edits themselves must happen in main context (so the user sees the diffs), but everything that *informs* the edits can be delegated. If you find yourself about to read a fourth file just to understand a pattern, stop and spawn a subagent instead.

When the implementation is done, collect the background test agent's results and reconcile. The tester worked from the spec alone, so fix any guessed names, signatures, or import paths to match the real implementation — keep the test intent. Then run the suite. A test that still fails points at an implementation gap: fix the implementation, not the test, unless the test misreads the spec.

Append `- implement: done` to the state file.

### Step 5: Simplify and commit

Invoke `/simplify` (bundled Claude slash command — not a skill). It applies its own fixes. Note anything it flags but declines to change — those items feed the explain-open wrap-up in Step 10.

Then commit. Use a message that matches the situation:

- If this run produced a fresh implementation in Step 4: `"Initial implementation: $SLUG"`
- If resuming or adopting work that predates this run: `"Continue work on $SLUG"`

```text
Skill("commit", args: "--force <message>")
```

Append `- simplify-commit: <short HEAD sha>` to the state file — also when `/simplify` made no changes and there was nothing to commit, so the step doesn't rerun.

### Step 6: Open a draft PR (if needed)

Check for an existing PR on the current branch:

```bash
gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number // empty'
```

If the output is non-empty, a PR already exists — leave it alone and move on. If the output is empty, open one as a draft:

```text
Skill("create-pr", args: "--force")
```

Append `- pr: <number>` to the state file.

### Step 7: Request a ReviewHog round

If `SKIP_REVIEWHOG` is true, record `- reviewhog-requested: skipped` and go to Step 8.

Push any unpushed commits first so ReviewHog reviews the branch's current state, then add the label that triggers its round:

```bash
git push 2>/dev/null
gh pr edit "$PR_NUMBER" --add-label reviewhog
```

If the label add fails (the repo has no `reviewhog` label), tell the user, set `SKIP_REVIEWHOG=true`, and record `- reviewhog-requested: skipped`. Otherwise record `- reviewhog-requested: done`. Either way, continue immediately — ReviewHog works in the background while Step 8 runs.

### Step 8: Review our own side while ReviewHog works

Run the full reviewer fleet against the PR and apply the clean fixes:

```text
Skill("review-code", args: "<pr-url> --fix")
```

Its Fix Summary lists what was fixed, what needs a judgment call, and what it declined to fix — keep that in reach: Step 9 compares it against ReviewHog's round and Step 10 explains the open items.

Commit the fixes but **don't push** — a mid-round push can retrigger ReviewHog and extend the wait; `wait-for-pr-reviews` owns the single push at the end of Step 9:

```text
Skill("commit", args: "--force Address review findings")
```

Append `- review-code: <short HEAD sha>`. If ReviewHog was skipped, push now (`git push`) since Step 9's wait won't run.

### Step 9: Wait for ReviewHog, address every review

If `SKIP_REVIEWHOG` is true, go to Step 10.

Hand the wait and the comment processing to the skill built for it:

```text
Skill("wait-for-pr-reviews")
```

It detects the in-flight ReviewHog round (and any other pending reviewers), runs `address-pr-reviews` on comments that already exist while waiting, re-runs it when the round lands, and pushes once at the end. Replies to human reviewers surface for approval per that skill's own rules — never auto-posted.

**Then log ReviewHog's misses.** Compare `review-code`'s legit findings from Step 8 — the fixed ones plus real-but-deferred items from its Fix Summary — against everything ReviewHog raised this round. Append each legit finding ReviewHog didn't also flag to `~/dev/haacked/notes/PostHog/reviewhog-gaps.md` (create the file if needed), one dated entry per run:

```markdown
## 2026-08-15 · PostHog/posthog#123 · e4f5a6b
- [correctness] `plugin-server/src/worker.ts:42` — off-by-one in retry backoff (fixed)
- [testing] `frontend/src/lib/api.test.ts` — new endpoint has no error-path test (deferred)
```

This file aggregates across repos and runs to feed ReviewHog improvements later — keep entries one line each, tagged with the review dimension, and note whether the finding was fixed or deferred. If ReviewHog never delivered a round (the wait timed out), say so in the entry header instead of logging misses — no round means no basis for comparison.

Append `- reviews-addressed: <short HEAD sha>`.

### Step 10: Explain open items and report

Gather every loose end the run accumulated: items `/simplify` flagged but didn't change, `review-code` Fix Summary items needing judgment or declined, entries in `.notes/review-skipped.md` (if present), and comments `address-pr-reviews` held for the user rather than acting on. Then have them explained:

```text
Skill("explain-open")
```

It translates each open or skipped item into plain English, weighs both sides, and recommends a call — this is the part of the report that needs the user's judgment, so lead with it.

Then report the rest:

- Commits added during the run (`git log @{u}..HEAD --oneline` or the range since the initial commit from Step 5)
- The PR URL (`gh pr view --json url -q .url`)
- ReviewHog gaps logged this run (count and the `reviewhog-gaps.md` path), or that ReviewHog was skipped/timed out
- Any drafted replies to human reviewers awaiting approval — these are never posted automatically

If any step failed, tell the user which one and what's needed to finish it; the state file keeps it as the resume point for the next `/go`.

The state file now records the full pipeline at HEAD, so re-running `/go` reports all-done and stops — until new commits or edits land, which mark the affected steps stale again.
