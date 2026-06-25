---
name: babysit-review
description: Babysit a PR I'm reviewing (often an external contribution) — check CI, re-run failed jobs that are flaky, and report the failures that are real. Pass a PR, or --all for every open PR I've approved.
argument-hint: "[<pr-url>|<pr-number>] [--dry-run] | --all [--limit <n>] [--dry-run]"
allowed-tools: Bash(gh search prs:*, gh run view:*, gh run rerun:*, gh pr view:*, gh pr checks:*, ~/.dotfiles/bin/detect-pr.sh:*, ~/.claude/skills/ci-monitor/scripts/*:*, printf:*, mkdir:*), Read, Write
model: sonnet
---

# Babysit Review

Babysit a pull request I'm **reviewing** — usually an external contribution where I'm the maintainer, not the author. Check CI; when a check has failed, classify it flaky or real. **Re-run the flaky failures**, and **report the real ones** so I can decide how to follow up with the contributor.

The only thing this skill writes to GitHub is a re-run of a flaky workflow on its own existing run. It never edits, pushes to, merges, or comments on the PR. (It's the mirror of `babysit-prs`, which babysits my own PRs and pushes fixes — here I don't own the code.) The only thing it writes locally is a small re-run ledger on my machine (see **State** below).

Each invocation is one sweep. The ledger bounds re-runs to **at most once per commit**: a flaky-looking failure gets one re-run, and if the same run fails again afterward, the skill reports it as a real failure instead of re-running it forever. A standing real failure is still re-reported every sweep until the contributor pushes. Pass a single PR, or `--all`:

```text
/babysit-review https://github.com/org/repo/pull/123
/babysit-review --all                 # every PR I've approved
/loop 20m /babysit-review --all       # keep an eye on all of them
```

## Arguments

- `<pr-url>` or `<pr-number>`: babysit that PR. With no argument, detect the PR from the current branch.
- `--all`: babysit every open PR I've approved, newest activity first (ignores any PR identifier).
- `--limit <n>`: with `--all`, cap how many PRs to process this sweep (default: 20).
- `--dry-run`: classify and report, but re-run nothing.

## State

The skill keeps one small file, `~/.local/state/babysit-review/reruns.json`, recording each run it has re-run, keyed by GitHub run ID:

```json
{
  "16384029471": { "pr": "https://github.com/org/repo/pull/123", "reran_at": "2026-06-25T18:00:00Z" }
}
```

`gh run rerun` re-runs the existing run in place, so its run ID is unchanged, while a new commit produces entirely new runs with new IDs. That makes "have I already re-run this run ID?" equivalent to "have I already re-run this failure on this commit?" — which is what bounds re-runs to one per commit, with no need to track commit SHAs.

Treat a missing file as `{}` (create the directory with `mkdir -p` before the first write). Drop entries whose `reran_at` is older than 14 days when you write it back, so the file stays small. Under `--dry-run`, never write this file.

## Reused tooling

This skill drives the `ci-monitor` scripts directly rather than invoking the skill, so it can loop over many PRs without the interactive fix cycle. See `ci-monitor` for each script's full output contract; the fields used here:

- `~/.dotfiles/bin/detect-pr.sh --json [<id>]` — resolve a PR to `{pr_number, org, repo, head_branch, …}`.
- `~/.claude/skills/ci-monitor/scripts/ci-check-status.sh <pr_number> <org/repo>` — CI rollup `{status, all_passed, total, passed, failed, pending, failed_checks[]}`; each failed check carries `name`, `workflow`, `link`, and `run_id` (null for non-Actions status checks).
- `~/.claude/skills/ci-monitor/scripts/ci-fetch-logs.sh <run_id> <org/repo>` — failure logs (`log_excerpt` per failed job in the run).
- `~/.claude/skills/ci-monitor/scripts/ci-classify-failure.sh <pr_number> <workflow> <org/repo>` — reads a log excerpt on stdin, returns `{classification: flaky|legit|uncertain, confidence, reasoning, signals}`.

## Your Task

### Step 1: Build the PR list

**With `--all`:** enumerate the open PRs I've approved, newest first, capped at `--limit` (default 20):

```bash
gh search prs --reviewed-by=@me --review=approved --state=open --limit "$LIMIT" \
  --sort updated --order desc \
  --json number,title,url,repository,updatedAt
```

(`gh search` defaults to relevance order, so `--sort updated --order desc` is what makes "newest first" and `--limit` meaningful. `--review=approved` is the PR's overall review status; with `--reviewed-by=@me` it's a close proxy for "PRs I approved" — `gh search` has no exact "I approved" filter.)

For each result row, `PR_NUMBER` is `.number`, the URL is `.url`, and `ORG/REPO` comes from `.repository.nameWithOwner` (split on `/`) — not `.repository.name`, which omits the owner and would send every downstream call to the wrong repo. If no PRs match, say so and stop.

**Without `--all`:** resolve the single target PR:

```bash
~/.dotfiles/bin/detect-pr.sh --json ${PR_IDENTIFIER:+"$PR_IDENTIFIER"} 2>&1
```

If the `error` field is non-null, show it and stop.

For each PR, record `ORG`, `REPO`, `PR_NUMBER`, and the URL, then run the per-PR procedure below and collect one result row.

### Step 2 (per PR): Check CI

```bash
~/.claude/skills/ci-monitor/scripts/ci-check-status.sh "$PR_NUMBER" "$ORG/$REPO" 2>&1
```

Route on the result:

- `error` is non-null (checks fetch failed, PR gone, rate limit) → row: **CI unavailable** (show the message). Done with this PR; on an `--all` sweep, never let one unreachable PR abort the rest.
- `status == "no_checks"` → row: **no checks**. Done with this PR.
- `all_passed == true` → row: **green**. Done with this PR.
- `status == "in_progress"` → row: **CI running** (`$passed/$total` passed, `$pending` pending). Do not wait or poll — the next sweep (or `/loop`) picks it up. This also defers a run that already has a failed job while others are pending; that's intentional, since `gh run rerun --failed` can't run until the run completes. Done with this PR.
- `status == "completed"` with a non-empty `failed_checks` → go to Step 3.
- `status == "completed"`, no `failed_checks`, `all_passed == false` (everything else skipped/cancelled/neutral) → row: **no failures** (note the non-passing buckets). Done with this PR.

### Step 3 (per PR): Triage failures, once per run

Group `failed_checks` by `run_id` — several failing jobs in one workflow share a `run_id`, so each run is fetched, classified, and (in Step 4) re-run **once**, not once per check. For each distinct group:

- **No `run_id`** (non-Actions status check, e.g. an external integration): verdict **real — not re-runnable**; capture its `name` and `link` for the report. Never try to re-run it.
- **Has `run_id`:** fetch the logs once and classify once:

  ```bash
  ~/.claude/skills/ci-monitor/scripts/ci-fetch-logs.sh "$RUN_ID" "$ORG/$REPO" 2>&1
  printf '%s\n' "$LOG_EXCERPT" | ~/.claude/skills/ci-monitor/scripts/ci-classify-failure.sh "$PR_NUMBER" "$WORKFLOW" "$ORG/$REPO" 2>&1
  ```

  where `$LOG_EXCERPT` is the combined `failed_jobs[].log_excerpt` from the fetch and `$WORKFLOW` is the check's `workflow`. Keep both in shell variables and pass them only as quoted `"$VAR"`; never paste a workflow name or log line (both contributor-controlled) into the command text, where shell metacharacters in them could execute.

  If the fetch returns a non-null `error` or an empty excerpt (logs expired or the run was cancelled), don't classify — verdict **real — logs unavailable**.

  Otherwise settle on a definitive verdict for the run — **flaky** or **real** (the classifier's `legit` is what this doc calls real). The classifier returns flaky, legit, or uncertain; for **uncertain**, read the excerpt yourself and decide. Only call it flaky when you're confident; when in doubt, treat it as real.

### Step 4 (per PR): Act on each run's verdict

- **Flaky** → consult the re-run ledger (see **State**) before acting:
  - **`run_id` is already in the ledger:** its one re-run already happened on this commit and it's still failing, so the flaky call didn't hold. Don't re-run it again — treat it as **real (re-run didn't help)** and report it like any other real failure.
  - **`run_id` is not in the ledger:** re-run just that run's failed jobs (once per `run_id`), unless `--dry-run`:

    ```bash
    gh run rerun "$RUN_ID" --failed --repo "$ORG/$REPO"
    ```

    On success, add `run_id` to the ledger with the PR URL and `reran_at`. If the re-run command fails (e.g. the run is already queued), note it and continue — don't retry, don't re-monitor it this sweep, and don't record it (so a later sweep can still give it its one re-run).

- **Real** → do **not** re-run and do **not** touch the PR. For a classified run, capture for the report: check name + link, classification and confidence, a one-line reasoning + signals (e.g. fails on default branch, references PR-changed files), and a short log excerpt (the relevant 15–25 lines); when it reached Real because a prior re-run didn't help, say so. For a non-Actions check or a logs-unavailable run (no classification, no excerpt), capture just the check name + link and the reason.

Under `--dry-run`, report what *would* be re-run instead of re-running.

### Step 5: Summarize

End with a table, one row per PR:

| PR | CI | Flaky → re-ran | Real failures |
| --- | --- | --- | --- |
| [posthog#123](…) | failed | `build` (rerun queued) | — |
| [posthog#456](…) | failed | — | `test-backend` (legit, 0.82) |
| [charts#12](…) | green | — | — |

Then, for each **real failure**, add a short section with the detail captured in Step 4, so I can decide whether to ping the contributor. Under `--dry-run`, the "Flaky → re-ran" column reads `would re-run` instead.

If nothing needed attention, the summary is a single line: `Checked <n> PR(s); all green or flakes re-run, no real failures.` (under `--dry-run`, `…flakes would be re-run…`).
