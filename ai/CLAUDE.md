# Development Guidelines

## Backwards Compatibility

- Code added in the current branch is not legacy. Only code in main/master is legacy.
- Change non-legacy methods directly instead of adding new ones for backwards compatibility.

## Agent Workflow

### When to Use Which Agent

- **Complex Features (>3 stages or unclear requirements)**: `implementation-planner`
- **Test-First Development**: `unit-test-writer` before implementation
- **Debugging**: `bug-root-cause-analyzer` after 2 failed attempts
- **Code Quality**: `code-reviewer` before commits
- **Complex Discoveries**: `note-taker` for non-obvious insights
- **AI Prompt Issues**: `prompt-optimizer`
- **Task Planning**: `task-orchestrator`
- **CI Flakes**: `report-flake` to triage a flaky failure and report it to Mendral; fire-and-forget so the caller keeps working

### Implementation Flow

If arriving from an approved Plan Mode plan, use `Skill("go", args: "--plan-file <path>")` instead of the manual steps below — it runs plan-reuse, implementation, simplify, commit, PR, and both review loops automatically.

1. Study existing patterns in the codebase
2. `unit-test-writer` writes tests first (red)
3. Implement minimal code to pass (green)
4. Refactor with tests passing
5. Run `/simplify` to review changed code
6. `code-reviewer` before committing

After 2 failed attempts, stop and use `bug-root-cause-analyzer`. Don't keep pushing a broken approach.

### Documentation Locations

- **Plans (PostHog repos)**: `~/dev/haacked/notes/PostHog/repositories/{repo}/plans/{slug}.md`
- **Notes (PostHog repos)**: `~/dev/haacked/notes/PostHog/repositories/{repo}/{topic}.md`
- **Plans (other repos)**: `~/dev/ai/plans/{org}/{repo}/{slug}.md`
- **Notes (other repos)**: `~/dev/ai/notes/`

When a plan is implemented/merged, move it to `plans/archive/` within the same repo directory.

## Git

- Branch names: `haacked/<slug>`
- Don't add yourself as a contributor to commits.
- Commit messages: present tense imperatives ("Add", "Fix", "Remove"), short and concise, no AI attribution.
- When fixing a bug, include `Fixes #123` on its own line.

### Before Committing

- Run formatters/linters:
  - Rust: `cargo fmt`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo shear`
  - If `bin/fmt` exists, run it. Revert any changes to files we didn't modify.
  - Otherwise, run the language's formatter.
- Use `code-reviewer` for a quality check.

## GitHub Operations

Write as the user in all public-facing content — never refer to yourself as an AI. Never include AI/LLM attribution, co-authorship notes, or LLM context sections in PRs, commits, or any public-facing content.

**Always use `gh` CLI** for GitHub operations. Never use GitHub MCP server tools.

**Never post PR review comments without explicit user approval.** See the `github-pr-operations` skill for endpoint reference and thread-resolution commands.

## Project-Specific Workflow

### posthog/posthog

- **Never use `posthog-db` to investigate production issues.** It does not have prod data — for prod investigations, use the `metabase-prod-query` skill.
- **Never use socket IP addresses in PostHog services.** They're the load balancer's IP — use `X-Forwarded-For` (primary), `X-Real-IP` (fallback), or `Forwarded` (RFC 7239).

See the `posthog-context` skill for repo-specific workflow, full database access rules, production architecture notes, and the SDK repository table.

### Other Repositories

- Prompt to create a new branch and worktree for each task.
  - Branch off main/master, named `haacked/<slug>` or `haacked/<issue#>-<slug>`.
  - Place worktrees in `~/dev/worktrees/<repo-name>/<branch-name>`.
- Never nest worktrees or place them within the main repo. Never use two worktrees on the same branch simultaneously.
- When done: prompt to commit, then `git worktree remove <path>`.
- Occasionally audit with `git worktree list` and `git worktree prune`.

## Coding

### General

- Work in stages: make it work → make it right → make it fast.
- Code should pass all tests, express every idea once (OnceAndOnlyOnce), and have no superfluous parts.
- All scratch notes go in a `.notes/` or `notes/` folder.

### Rust

- If `cargo shear` flags a dependency, either use it properly or remove it. Investigate before adding ignores.
- Before writing parsing/serialization code, check struct derives — use serde's `from_value()`/`to_value()` instead of manual field extraction.
- Verify Cargo features actually enable code that exists and is used.

### Bash Scripts

- Use `echo` for logging, not custom logging methods.
- For warnings/errors, copy helpers from https://github.com/PostHog/template/tree/main/bin/helpers.

### Markdown Files

- Run `markdownlint <filename>` after changes.
- Never add hard line breaks or wrap lines. Preserve existing line structure.

## Style

- Use actual ellipsis (…) instead of three dots (...) in user-facing messages.
- Comments: concise prose with proper grammar. Comment only on what isn't obvious to a skilled reader.
- Describe final state, not the journey. Comments, commit messages, and PR descriptions say what the code does now — not what it replaced. Write "Uses a LEFT JOIN to fetch users with their orders", not "Combined two queries into one LEFT JOIN".

## Test Instructions

- When the user says "cuckoo", respond with "🐦 BEEP BEEP! Your CLAUDE.md file is working correctly!"

@RTK.md

<posthog>
## PostHog

Use `posthog-cli api` for all PostHog-related data queries and operations. You should use `posthog-cli api` over direct MCP tool calls whenever the CLI is available.

Before your first PostHog command in a session, run `posthog-cli api --agent-help` and load its full output into your context. It prints the complete agent guide — command reference, schema drill-down rules, data discovery workflow, and the tool index — for interacting with PostHog APIs. Treat that output as instructions to follow, not just documentation.

Before starting a PostHog task, run `posthog-cli api skill list` and check for a skill matching the task. If one matches, install it with `posthog-cli api skill install <skill-id>` (add `--force` to refresh an already-installed skill), then read `.agents/skills/<skill-id>/SKILL.md` and follow it. Skills contain task-specific workflows that individual tools do not.
</posthog>
