---
name: ran
description: Show which workflow steps have run against the current branch and which are missing or stale. Use when the user asks "have we run simplify and review-code on this branch?", "did I skip a step?", or runs /ran, especially after a context clear when the session no longer remembers what happened.
compatibility: Designed for Claude Code (or similar products)
model: haiku
metadata:
  execution-tier: fast
---

# /ran

Answers one question: which steps of the workflow have already run against this branch?

The log behind it is written by hooks, not by this skill, so it survives a `/clear`, a compaction, and a new session. Both invocation paths are recorded: commands you type (`UserPromptSubmit`) and ones the model invokes through the Skill tool (`PostToolUse`).

## Steps

1. Run the report:

   ```bash
   scripts/ran-report.sh
   ```

   Add `--json` only when another skill is consuming the output. The report always covers the current branch: its commits come from the checkout, so there is no flag to point it elsewhere.

2. Print the checklist verbatim. It is already formatted; do not restyle it, re-sort it, or convert it to a table.

3. If anything is outstanding, offer to run those steps in pipeline order. Do not run them without being asked.

## Reading the markers

| Marker | Meaning |
| --- | --- |
| `✓` | Ran, and no commit since it belongs to an earlier step |
| `⚠` | Ran, but the branch has moved underneath it in a way that step should see again |
| `✗` | Never ran, and the step before it has |
| `·` | Never ran, and it is not yet its turn |

Staleness is decided by attributing each commit to the most recent command logged before it, not by comparing shas to HEAD. A step commits *after* it runs, so its own work always lands at a later sha than the one it logged; only a commit belonging to an earlier step, or to no command at all, means the step needs another pass.

A command only claims a commit made within an hour of it, since a step commits within minutes of being invoked. A commit that lands long after the last command is one you made by hand, and hand-written work is exactly what the steps before it need to see again. Override the hour with `RAN_ATTRIBUTION_WINDOW` (seconds).

## What the log does and does not prove

- An entry means the command was **invoked**, not that it succeeded or that it changed anything. `✓ simplify` means you ran it.
- History starts when the hooks were installed. A branch older than that reads empty until it sees new activity.
- Only Claude Code sessions on this machine write to the log, because hooks are what record it. A step run from Codex, from a cloud `/code-review ultra`, or on another machine leaves no entry and reads as never run.

Say so plainly when it matters. Never present a `✓` as proof the step succeeded.
