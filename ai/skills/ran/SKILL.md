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

Most rows come from a log written by hooks, not by this skill, so it survives a `/clear`, a compaction, and a new session. Both invocation paths are recorded: commands you type (`UserPromptSubmit`) and ones the model invokes through the Skill tool (`PostToolUse`).

Three rows read their result directly instead of the log, so it does not matter how the step ran:

| Row | Reads | Fresh when |
| --- | --- | --- |
| `commit` | the working tree | nothing is uncommitted and the branch has commits |
| `create-pr` | the branch's PR | a PR is open, a draft, or merged |
| `ci-monitor` | the checks on the PR's head | the PR's head is HEAD and its checks passed |

The report makes one GitHub call for these rows and for the review threads `address-pr-reviews` reads. When GitHub does not answer, those rows read only the log, and the report's last line names them. The call looks the PR up in `origin`'s repository by the local branch name, so it finds no PR when the PR comes from a fork or when the local branch has a different name from the PR's branch, as after `gh pr checkout` can leave it.

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
| `✗` | Never ran, and the last required step before it has |
| `…` | CI is still running on HEAD |
| `·` | Never ran, and it is not yet its turn |

Staleness is decided by attributing each commit to the most recent command logged before it, not by comparing shas to HEAD. A step commits *after* it runs, so its own work always lands at a later sha than the one it logged; only a commit belonging to an earlier step, or to no command at all, means the step needs another pass. A stale row names those commits: `by hand`, `by <step>`, or `rewritten`.

A command only claims a commit made within an hour of it, since a step commits within minutes of being invoked. A commit that lands long after the last command is one you made by hand, and hand-written work is exactly what the steps before it need to see again. Override the hour with `RAN_ATTRIBUTION_WINDOW` (seconds).

A rebase gives every commit a new sha and a new committer time. A commit whose patch matches one the branch held before the rebase keeps that earlier commit's time, so a rebase alone does not make a step stale. A commit whose patch changed, because a rebase resolved a conflict in it or an amend edited it, matches nothing. Whitespace counts, so a re-indent is a change. Such a commit keeps its new committer time and reads as `rewritten`, and the steps before it go stale, because nobody has reviewed the change. A rebase run with `--committer-date-is-author-date` gives a changed commit its old time back, so the change hides under the run that came before it. A patch that left the branch while a step ran, as when an amend replaced it and a later amend restored it, counts from when it came back, because that step never saw it. The branch's reflog is what names the earlier commits, so a fresh clone treats every rebased commit as `rewritten`.

A row shows the commit its step produced, or else the sha the log recorded. When a rebase carried that commit over unchanged, the row shows the new sha. When the branch no longer holds it, the row says so. A time from an earlier day shows the day, as `Fri 15:20`.

## What the log does and does not prove

- For `simplify` and `comment-cleanup`, an entry means the command was **invoked**, not that it succeeded or that it changed anything. `✓ simplify` means you ran it.
- `review-code` and `address-pr-reviews` count only the record a review skill writes as its last action, so `✓` there means the pass finished. A review abandoned at the prompt reads `✗`.
- That exception is only as wide as the callers that write it. `/go`, `/review-fix-cycle`, and `/address-pr-reviews` record completion. A bare `/review-code` does not, because that skill lives outside this repo, and neither does `/code-review`, which is built into Claude Code. A review run either of those ways, or by a reviewer subagent spawned directly, reads as never run and the step gets offered again. To credit such a review, run `~/.dotfiles/ai/bin/log-step-done.sh review-code` once it has finished and its findings are handled.
- An unresolved review thread whose latest comment someone else posted after the last recorded pass started makes `address-pr-reviews` stale, because that pass may never have seen the comment. Threads the pass fixed or dismissed stay unresolved, and they do not count, because their comments predate the pass. The report reads the first 100 threads, so a PR with more than that reads stale. The PR never makes the row fresh on its own.
- History starts when the hooks were installed. A branch older than that reads empty until it sees new activity, and its pre-existing entries never satisfy the two review steps.
- Hooks are what record an invocation, so only Claude Code sessions on this machine write those. A step run from Codex, from a cloud `/code-review ultra`, or on another machine leaves no invocation entry. A skill that records its own completion is the exception again: it writes wherever it runs, Codex included.

Say so plainly when it matters. For `simplify` and `comment-cleanup`, never present a `✓` as proof the step succeeded.
