---
name: babysit-prs
description: One sweep over all of my open PRs — check CI, handle new review comments, fix and push — tracking state so reruns skip already-handled work. Designed to be driven by /loop.
argument-hint: "[--owner <org>] [--limit <n>] [--dry-run]"
allowed-tools: Bash, Read, Write, Edit, Glob, Grep, Skill
model: sonnet
---

# Babysit PRs

Perform **one sweep** over my open pull requests: for each PR, check CI health and unhandled review comments, dispatch fixes through the existing `ci-monitor` and `copilot-review` skills, and record what was handled so the next sweep skips it.

This skill does a single iteration on purpose. Run it continuously with the loop runner:

```text
/loop 20m /babysit-prs
/loop /babysit-prs          # self-paced
```

## Arguments

- `--owner <org>`: only sweep PRs in repos owned by `<org>` (repeatable). Default: all my open PRs.
- `--limit <n>`: max PRs to process this sweep (default: 10, newest activity first).
- `--dry-run`: report what would be done; take no fix actions and don't update state.

## State

State lives in `~/.local/state/babysit-prs/state.json`, keyed by PR URL:

```json
{
  "https://github.com/PostHog/posthog/pull/123": {
    "updated_at": "2026-06-09T17:05:00Z",
    "head_sha": "abc123",
    "ci_conclusion": "success",
    "last_comment_at": "2026-06-09T17:00:00Z"
  }
}
```

A PR is **quiet** (skip it) when its current head SHA matches `head_sha`, its CI conclusion is unchanged and not failing, and it has no review comments newer than `last_comment_at`. Anything else makes it **active**. `updated_at` is a cheap pre-filter, but only when the stored `ci_conclusion` is terminal-good (`success` or `skipped`): completing check runs do not bump a PR's `updatedAt`, so a PR recorded as pending or failing still needs the per-PR fetch even when `updatedAt` is unchanged.

## Your Task

### Step 1: Enumerate Open PRs

```bash
gh search prs --author=@me --state=open --limit 50 \
  --json number,title,url,repository,isDraft,updatedAt
```

If `--owner` was given, add `--owner <org>` to the search. Sort by `updatedAt` descending and keep the first `--limit` PRs. Read the state file (treat a missing file as `{}`).

### Step 2: Classify Each PR

If a PR's `updatedAt` from Step 1 matches the state file's `updated_at` AND its stored `ci_conclusion` is terminal-good (`success` or `skipped`), mark it quiet without any further calls; on an all-quiet sweep, the search query is the only API call made. PRs recorded as pending or failing always get the per-PR fetch until CI concludes green. For the remaining PRs, fetch the facts needed to compare against state:

```bash
gh pr view <url> --json headRefOid,statusCheckRollup,reviewDecision,isDraft \
  --jq '{headRefOid, reviewDecision, isDraft, conclusions: ([.statusCheckRollup[].conclusion] | unique), failing: [.statusCheckRollup[] | select(.conclusion == "FAILURE") | {name, detailsUrl}]}'
gh api 'repos/<owner>/<repo>/pulls/<number>/comments?sort=created&direction=desc&per_page=20' --jq '[.[] | {id, user: .user.login, created_at}]'
```

Classify:

- **Quiet**: matches the state file as defined above. Skip; no per-PR output beyond the summary table.
- **CI failing or pending-after-push**: head SHA differs from state, or `conclusions` contains `"FAILURE"` or does not yet contain a terminal value.
- **New comments**: review comments newer than `last_comment_at` from anyone other than me.

### Step 3: Locate a Checkout (only for PRs needing fixes)

Fix work needs a local checkout of the PR branch:

1. Look for an existing clone: `~/dev/posthog/<repo>` for PostHog org, `~/dev/<owner>/<repo>` otherwise, `~/.dotfiles` for dotfiles.
2. In the clone, check whether the PR branch is already checked out somewhere and use that path if so (never create a second worktree for the same branch):

   ```bash
   source ~/.dotfiles/bin/lib/git-worktree.sh && worktree_path_for "<branch>"
   ```

3. Otherwise create one: `git worktree add ~/dev/worktrees/<repo>/<branch> <branch>` (fetch first).
4. No local clone at all: skip the PR and flag it in the summary so I can clone it.

### Step 4: Dispatch

Handle each active PR, working from its checkout:

- **CI failing** → invoke the `ci-monitor` skill with the PR URL. It classifies flaky vs legit failures and fixes legit ones.
- **New review comments** → invoke the `copilot-review` skill with the PR URL. It evaluates each comment, fixes legitimate findings, and handles replies per its own rules.
- Push resulting commits to the PR branch. Never force-push. Never merge, close, or mark ready-for-review.

If a dispatch fails twice for the same PR, record the failure in the summary and move on; don't retry within the sweep.

### Step 5: Update State and Summarize

After handling (or skipping) each PR, write its current `updated_at`, `head_sha`, `ci_conclusion`, and newest `last_comment_at` back to the state file, and drop any state keys not present in the Step 1 search results so closed and merged PRs don't accumulate (skip this entirely under `--dry-run`).

End with a summary table:

| PR | Status | Action taken |
| --- | --- | --- |
| [posthog#123](…) | CI failing (legit) | Fixed test, pushed `def456` |
| [posthog#456](…) | 2 new comments | 1 fixed, 1 reply drafted |
| [charts#12](…) | quiet | skipped |

If every PR was quiet, the summary is the single line: `All <n> open PRs quiet; nothing to do.`
