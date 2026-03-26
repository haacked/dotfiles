---
name: test-plan
description: Generate a GitHub Flavored Markdown test plan checklist. Use when the user wants to create a test plan for a PR or an implementation plan.
argument-hint: "[--force] [--save <path>] [--plan <file>]"
---

# Test Plan Generator

Generate a structured test plan as a GFM checklist. Supports two mutually exclusive input modes:

- **Branch mode** (default) — analyze the current branch's diff against base
- **Plan mode** (`--plan <file>`) — analyze an implementation plan file

## Arguments

- `--force` — skip preview and confirmation; save immediately
- `--plan <file>` — path to an implementation plan file (skip git analysis, use this file as input)
- `--save <path>` — custom output path (default: `.context/test-plan.md`)

Example invocations:

- `/test-plan` — generate from current branch diff
- `/test-plan --plan ./plans/my-feature.md` — generate from plan file
- `/test-plan --save /tmp/test-plan.md` — generate from branch, save to custom path
- `/test-plan --force` — generate from branch, skip confirmation
- `/test-plan --plan ./plan.md --save /tmp/test-plan.md` — plan mode with custom save path

## Steps

### 1. Parse Arguments

Extract from user input:

- `force` = true if `--force` is present
- `plan_file` = path after `--plan`, or empty (branch mode)
- `save_path` = path after `--save`, or `.context/test-plan.md`

If `--plan` is provided, use plan mode. Otherwise, use branch mode.

### 2. Gather Context

#### Branch mode (no `--plan`)

Determine the base branch using the shared helper:

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

No git operations are needed in plan mode.

### 3. Analyze Input

Read the diff or plan carefully. The goal is to produce test items specific enough that a reviewer who did not write the code can follow them exactly. Generic items like "verify cache invalidation works" are not acceptable.

Extract and record these concrete details from the source material — you will embed them verbatim in test items:

- **Literal identifiers**: constant names, cache key patterns (e.g., `posthog:auth_token:{sha256_hash}`), token prefixes (e.g., `phs_`, `phx_`), field names (e.g., `scoped_teams`, `org_ids`), enum values, signal names
- **Boundaries and integration points**: every place the code crosses a system boundary (API endpoint → database, Python → Redis → Rust, signal handler → async task, model save → cache invalidation)
- **State transitions that trigger behavior**: which model fields, when saved or deleted, cause which downstream effects — and which do NOT
- **Conditional logic**: branches where one path causes an effect and the other does not; these generate pairs of positive and negative test items
- **Security-sensitive paths**: authentication checks, permission scoping, token rotation, access denial
- **Assumptions that could silently break**: hash function compatibility between components, key format consistency, flag/feature parity between services

For each integration boundary or system behavior identified, draft test items that cover:
1. The happy path (the thing works as described)
2. The boundary condition (e.g., second request uses cache, not database)
3. The negative case (the behavior does NOT trigger when it should not)
4. The recovery case (after invalidation, the system re-fetches and works again)

### 4. Generate Test Plan

Produce a GFM markdown test plan following this structure:

```markdown
### Test plan

<One or two sentences: what the automated tests already cover, and what this manual plan focuses on instead.>

#### Prerequisites

- [ ] <Setup step with specific commands or config values required>

#### 1. <Section name scoped to one behavior or subsystem>

- [ ] <Specific action> — <concrete expected outcome, naming identifiers from the code>
- [ ] <Another scenario> — <expected outcome>

#### 2. <Next section>

- [ ] ...
```

**Section count and density:** Aim for one section per distinct behavior cluster (cache population, each invalidation trigger, validation logic, consistency checks). Each section should have 4–10 items. A complete test plan typically has 6–10 sections. Fewer than 4 sections or fewer than 20 total items usually means you have not gone deep enough.

**Item quality standard:** Every item must name the concrete thing being tested. Compare:

| Too vague — do not write this | Specific enough — write this instead |
|-------------------------------|--------------------------------------|
| Verify cache invalidation works after token rotation | Rotating a team's secret API token invalidates the discarded backup token's cache entry in Redis; the old primary (now backup) token's entry is NOT deleted |
| Test that scoped PAKs are rejected correctly | PAK with `scopes: ["session_recording:read"]` (no feature flag scope) is rejected when requesting flags |
| Check that creating a new key doesn't cause issues | Creating a new PAK does NOT trigger any cache invalidation (nothing cached yet) |

**Negative assertions are required.** Many of the most important items state what must NOT happen. Use phrasing like "does NOT trigger", "is NOT deleted", "does not cause". These prevent false positives in manual testing just as much as positive assertions.

**Use `- [ ]` for all items.** Leave checkboxes unchecked so the reviewer can check them off during testing.

**Prerequisites section:** Include only if setup beyond a running dev environment is needed (specific services, environment variables, feature flags, seed data). Name the exact commands or config values.

**Closing note:** If there are edge cases that are difficult to test manually (e.g., timing-dependent behavior, requires mocking internals), include the item anyway with a parenthetical note explaining the constraint, like: `_This is tricky to test because of debouncing_`.

### 5. Show Preview

If `force` is true, skip to Step 6 immediately.

Otherwise, display the generated test plan to the user:

```
Test plan preview:

<generated markdown>
```

Ask: "Save this test plan? Reply yes to confirm, or describe any changes."

Do not proceed until the user replies. If the user requests changes, update the plan and show the preview again.

### 6. Save to File

Create the parent directory if needed (`mkdir -p`), then write the test plan to `save_path`.

Report: "Test plan saved to `<save_path>`. You can paste its contents into your PR description."
