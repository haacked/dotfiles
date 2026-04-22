---
name: go
description: Plan, implement, and iteratively review a task end-to-end using Claude + Copilot reviewers in a linear flow.
argument-hint: "<task description> [--skip-planner] [--skip-copilot]"
---

# /go

End-to-end orchestrator: plan → implement → simplify → commit → open draft PR → Claude review loop → Copilot review loop → one final Claude review pass to catch anything Copilot's fixes introduced.

The expensive steps (`review-fix-loop.sh`, `copilot-review-loop.sh`) run each round in a fresh `claude -p` subprocess, so the main context only carries planning and the initial implementation.

## Arguments

- `<task description>` — what to build/fix. Required unless the branch already has uncommitted/unpushed work (see Step 1).
- `--skip-planner` — skip the `implementation-planner` sub-agent; implement directly from the description.
- `--skip-copilot` — skip the Copilot rounds and the final Claude pass. Useful when there's no PR yet or Copilot is unavailable.

## Steps

### Step 1: Parse arguments

Extract from `$ARGUMENTS`:

- `SKIP_PLANNER` — boolean, true if `--skip-planner` is present.
- `SKIP_COPILOT` — boolean, true if `--skip-copilot` is present.
- `TASK` — everything else, joined with spaces.
- `SLUG` — short kebab-case identifier derived from `TASK` (e.g. "add dark mode toggle" → "add-dark-mode-toggle"). Used in commit messages and planner descriptions.

If `TASK` is empty, check for in-flight work:

```bash
git status --porcelain
git log @{u}..HEAD --oneline 2>/dev/null || git log -5 --oneline
```

If the working tree is dirty or there are unpushed commits, set `CONTINUING=true`, derive `SLUG` from the most recent commit subject, and jump to Step 4. Otherwise stop and ask the user what to build.

### Step 2: Plan

If `SKIP_PLANNER` is true, skip this step.

Otherwise spawn the planner as a sub-agent so its research stays out of the main context:

```
Agent tool with:
  subagent_type: implementation-planner
  description: "Plan: $SLUG"
  prompt: <TASK> plus any relevant context from this conversation
```

The planner writes a plan file per its own contract.

### Step 3: Implement

Implement the change in the current context. Follow the plan file if one exists, otherwise work directly from `TASK`. This step is conversational — check in with the user on judgment calls.

### Step 4: Simplify and commit

Invoke `/simplify` (bundled Claude slash command — not a skill). It applies its own fixes.

Then commit. Use a message that matches the situation:

- If Step 3 produced a fresh implementation: `"Initial implementation: $SLUG"`
- If `CONTINUING=true` from Step 1: `"Continue work on $SLUG"`

```
Skill("commit", args: "--force <message>")
```

If `/simplify` made no changes and there's nothing to commit, skip this step.

### Step 5: Open a draft PR (if needed)

Check for an existing PR on the current branch:

```bash
gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number // empty'
```

If the output is non-empty, a PR already exists — leave it alone and move on. If the output is empty, open one as a draft:

```
Skill("create-pr", args: "--force --draft")
```

### Step 6: Claude review loop (until convergence)

Run the existing fresh-context review loop via the Bash tool:

```bash
~/.dotfiles/bin/review-fix-loop.sh
```

It iterates Claude review → fix → simplify → commit until a round comes back clean (or hits its own max-iterations). Exits 0 on clean, non-zero if findings remain.

### Step 7: Copilot review loop (until convergence)

If `SKIP_COPILOT` is true, skip to Step 9.

Otherwise run the Copilot loop against the current branch's PR:

```bash
~/.dotfiles/bin/copilot-review-loop.sh
```

It auto-detects the PR from the current branch, fetches Copilot's review, fixes legit findings, replies to dismissed ones, pushes, and repeats until Copilot has no new comments.

### Step 8: Final Claude pass

Rerun the Claude review loop once more to catch anything Copilot's fixes introduced:

```bash
~/.dotfiles/bin/review-fix-loop.sh
```

`review-fix-cycle` uses `--append` internally, so this pass only surfaces new findings. It typically exits clean on the first iteration.

### Step 9: Report

Tell the user what happened:

- Commits added during the run (`git log @{u}..HEAD --oneline` or the range since the initial commit from Step 4)
- The PR URL (`gh pr view --json url -q .url`)
- Any outstanding findings — check `.notes/review-skipped.md` for Claude's deferred items and the Copilot state file under `~/.local/state/copilot-review-loop/` for low-confidence Copilot items flagged for human review.

If any step exited non-zero, tell the user which one and where the logs are (`.notes/` for Claude, `~/.local/state/copilot-review-loop/` for Copilot).
