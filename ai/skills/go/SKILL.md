---
name: go
description: Plan, implement, and iteratively review a task end-to-end until Claude and Copilot reviewers both return clean in the same pass.
argument-hint: "<task description> [--max-cycles N] [--skip-planner] [--skip-copilot]"
---

# /go

End-to-end orchestrator. Plans the work (via the `implementation-planner` sub-agent), implements it, simplifies, commits, opens a draft PR, then hands off to `go-loop.sh` — a bash wrapper that alternates Claude and Copilot review loops with fresh contexts until neither reviewer finds anything to fix.

Inner review loops (`review-fix-loop.sh`, `copilot-review-loop.sh`) already handle per-reviewer convergence and run each iteration in a fresh `claude -p` subprocess, so the main context here only carries planning and the initial implementation.

## Arguments

- `<task description>` — what to build/fix. Required unless the branch already has uncommitted work (see Step 3).
- `--max-cycles N` — maximum outer convergence cycles (default 3).
- `--skip-planner` — skip the `implementation-planner` sub-agent; treat the description as the plan.
- `--skip-copilot` — run only the Claude review loop. Useful when there's no PR yet or Copilot is unavailable.

## Steps

### Step 1: Parse arguments

From `$ARGUMENTS`, extract:

- `MAX_CYCLES` — integer after `--max-cycles` (default `3`).
- `SKIP_PLANNER` — boolean, true if `--skip-planner` present.
- `SKIP_COPILOT` — boolean, true if `--skip-copilot` present.
- `TASK` — everything else, joined with spaces.

If `TASK` is empty, check `git status --porcelain` and `git log @{u}..HEAD --oneline` for uncommitted/unpushed work. If there's work to review, proceed with `TASK="(continuing existing work)"` and skip to Step 4. Otherwise stop and ask the user what to build.

### Step 2: Plan

If `SKIP_PLANNER` is false, spawn the planner as a sub-agent so its research doesn't pollute the main context:

```
Agent tool with:
  subagent_type: implementation-planner
  description: "Plan: <short slug>"
  prompt: <TASK> plus any context the user has shared in this conversation
```

Wait for the agent to finish. It will write a plan file under `~/dev/ai/plans/{org}/{repo}/<slug>.md` (see the planner's own contract).

If `SKIP_PLANNER` is true, skip this step. You'll implement directly from the task description.

### Step 3: Implement

Implement the change in the current context, following the plan file (or the task description if planning was skipped). Read code, write code, run tests — whatever the task requires. This step is conversational: check in with the user when judgment calls come up.

### Step 4: Simplify and commit

Run `/simplify` on the changes (bundled Claude slash command — just invoke it; do not use `Skill()`). It applies its own fixes.

Then invoke the commit skill:

```
Skill("commit", args: "--force Initial implementation: <short slug>")
```

### Step 5: Open or update a draft PR

Check for an existing PR on the current branch:

```bash
gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number'
```

If no PR exists, open a draft:

```
Skill("create-pr", args: "--force --draft")
```

If a PR already exists, skip this step — re-running `create-pr` could overwrite a manually edited title or body. Run `/create-pr` yourself afterwards if you want to refresh it.

### Step 6: Run the convergence loop

Shell out to the outer loop:

```bash
SKIP_ARG=""
if [[ "$SKIP_COPILOT" == "true" ]]; then
  SKIP_ARG="--skip-copilot"
fi

~/.dotfiles/bin/go-loop.sh --max-cycles "$MAX_CYCLES" $SKIP_ARG
```

The loop invokes `review-fix-loop.sh` and `copilot-review-loop.sh` in alternation, each in its own fresh-context subprocess, and writes `.notes/go-summary.json` when done.

### Step 7: Report

Read `.notes/go-summary.json` and print a concise summary:

```
/go complete.
Cycles: <cycles>/<max>
Converged: <true|false>
Claude fixes per cycle: <list>
Copilot fixes per cycle: <list>
PR: <url>
```

If `converged` is false, point to where the outstanding findings live:

- `.notes/review-skipped.md` — findings Claude flagged but couldn't fix
- The Copilot loop's per-PR state file (path printed by `copilot-review-loop.sh`) — Copilot round history
