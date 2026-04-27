---
name: test-plan
description: Generate a GitHub Flavored Markdown manual test plan checklist that focuses on scenarios not covered by existing unit/integration tests. Use when the user wants to create a test plan for a PR or an implementation plan.
argument-hint: "[--force] [--save <path>] [--plan <file>]"
---

# Test Plan Generator

Generate a manual test plan as a flat GFM checklist. Each item is a single line of the form `- [ ] <Title>: <Step>. <Step>. <Verification>.`.

The plan must focus on **end-to-end scenarios that automated unit and integration tests do NOT already cover** — behaviors that emerge from coordination between multiple units, crossings of system boundaries, or stateful interactions that are awkward or expensive to assert in code. Restating what unit tests already verify is wasted reviewer effort.

## Modes

- **Branch mode** (default) — analyze the current branch's diff against base
- **Plan mode** (`--plan <file>`) — analyze an implementation plan file

## Arguments

- `--force` — skip preview and confirmation; save immediately
- `--plan <file>` — path to an implementation plan file (skip git analysis, use this file as input)
- `--save <path>` — custom output path (default: `.context/test-plan.md`)

Example invocations:

- `/test-plan` — generate from current branch diff
- `/test-plan --plan ./plans/my-feature.md` — generate from plan file
- `/test-plan --save /tmp/test-plan.md` — custom save path
- `/test-plan --force` — skip preview and save immediately

## Steps

### 1. Parse Arguments

- `force` = true if `--force` is present
- `plan_file` = path after `--plan`, or empty (branch mode)
- `save_path` = path after `--save`, or `.context/test-plan.md`

### 2. Gather Context

#### Branch mode (no `--plan`)

Determine the base branch:

```bash
base="origin/$(bash "$HOME/.dotfiles/bin/lib/git-default-branch.sh")"
```

If the helper is not available, tell the user and **stop**.

Then run in parallel:

```bash
git log "$base"..HEAD --oneline
git diff "$base"..HEAD
```

If there are no commits ahead of base or the diff is empty, tell the user there are no changes to generate a test plan for and stop.

#### Plan mode (`--plan <file>`)

Read the specified plan file. If the file does not exist, tell the user and stop.

### 3. Identify Coverage Gaps

Before drafting items, identify what the automated tests in the diff already cover so the plan can avoid duplicating them.

Skim test files touched by the diff (`*.test.ts`, `*.test.tsx`, `test_*.py`, `*_test.go`, `*.spec.*`, etc.) and note the units, branches, and assertions they exercise. Treat anything well-covered there as **out of scope** for the manual plan.

Strong candidates for manual items (these usually escape unit/integration tests):

- **End-to-end flows** that span multiple services or layers (HTTP → app → DB → cache, signal handler → async task, model save → cache invalidation)
- **State on the other side of a boundary** — Redis cache entries, queued jobs, files written to disk, rows in a different table, side effects on an external API
- **Observability** — metrics emitted, log lines written, traces produced, alerts fired
- **Infrastructure-shaped behavior** — load balancer hops, ingress headers (`X-Forwarded-For`, `X-Real-IP`), feature flags, environment-specific config
- **UI behavior** — visible state changes, focus, keyboard navigation, error toasts, accessibility
- **Negative assertions** — paths that must NOT trigger a behavior, fields that must NOT invalidate a cache, scopes that must NOT grant access

Skip these (usually already asserted in code):

- Pure-function correctness covered by unit tests
- API request/response shape covered by integration tests
- Error message strings asserted in tests

### 4. Generate Test Plan

Produce a flat GFM checklist where each item is a single line:

```
- [ ] <Title>: <Action>. <Action>. <Verification>.
```

**Format rules:**

- Each item is one line — never wrap onto multiple lines
- Start with a short title naming the scenario, then `:`, then concrete imperative steps separated by periods, ending with a verification step
- Name concrete identifiers from the code verbatim: cache keys (e.g. `posthog:auth_token:<sha256>`), table names, env vars, metric names, header names, redis prefixes, signal names, token prefixes (`phs_`, `phx_`), enum values
- Cover both positive cases ("triggers", "sets", "is present") and negative cases ("does NOT trigger", "is NOT deleted", "remains unchanged")

**Examples in the target style:**

```
- [ ] Cache readthrough: Clear Redis. Make request to /flags. Confirm 200 response. Check Redis for key `posthog:flags:<team_id>`.
- [ ] Cache hit: After readthrough, make a second /flags request. Confirm logs show `flag_cache_hit` and DB query count is unchanged.
- [ ] Cache invalidation on token rotation: Rotate the team's secret API token. Confirm the old token's `posthog:auth_token:<sha256>` entry is gone from Redis.
- [ ] No invalidation on unrelated edit: Update the team's name. Confirm `posthog:flags:<team_id>` is still present.
- [ ] Forwarded IP respected: Send request with `X-Forwarded-For: 1.2.3.4`. Confirm rate-limit counter for `1.2.3.4` increments, not the load balancer's IP.
```

**Avoid:**

- Vague items like "verify cache invalidation works"
- Items that restate what an existing unit/integration test already asserts
- Multi-paragraph items or steps split across multiple lines
- Items missing a verification step

**Output structure:**

```markdown
## Test plan

<One sentence: what automated tests already cover, and what this manual plan focuses on.>

- [ ] <item>
- [ ] <item>
…
```

If there are more than ~10 items spanning clearly distinct subsystems, you may group them with `###` subheadings — but each item under a heading must still be a one-line checkbox.

**Difficult-to-test cases:** If a scenario requires conditions that are awkward to set up manually (timing-dependent behavior, requires fault injection, etc.), include it anyway with a short parenthetical, e.g. `(requires toxiproxy to simulate Redis failover)`.

### 5. Show Preview

If `force` is true, skip to Step 6.

Otherwise display the generated test plan and ask: "Save this test plan? Reply yes to confirm, or describe any changes."

Wait for the user's reply. If they request changes, update the plan and show the preview again.

### 6. Save to File

Create the parent directory if needed (`mkdir -p`), then write the test plan to `save_path`.

Report: "Test plan saved to `<save_path>`. The next `/create-pr` run in this branch will embed it in the PR's testing section automatically."
