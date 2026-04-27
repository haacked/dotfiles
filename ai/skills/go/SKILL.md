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

If a plan was found, read it with the Read tool, briefly tell the user which plan you're using, and skip to Step 3.

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

**Preserve context aggressively.** The review loops in Steps 6–8 run in fresh subprocesses, but Step 3 stays in main context through the rest of the run. Every file read and search compounds. Push expensive reads into subagents that return summaries instead of raw content:

- **Codebase exploration** (anything that would take more than ~3 greps/reads to answer): spawn `Explore`. Ask for the specific answer, not a file dump — e.g. "where is auth middleware registered and what's its call signature?" rather than "show me the auth code".
- **Writing tests**: spawn `unit-test-writer` with the target file/function. Don't read the test file into main context first — the subagent will.
- **Stuck after two failed fix attempts**: spawn `bug-root-cause-analyzer` rather than continuing to debug in main context.
- **Reading large generated files, lockfiles, fixtures, or logs**: spawn `general-purpose` with a narrow question. Never `Read` a file >500 lines into main context unless you actually need to edit it.

The edits themselves must happen in main context (so the user sees the diffs), but everything that *informs* the edits can be delegated. If you find yourself about to read a fourth file just to understand a pattern, stop and spawn a subagent instead.

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
