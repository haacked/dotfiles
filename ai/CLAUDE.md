# Development Guidelines

## Backwards Compatibility

- Code added in the current branch is not legacy. Only code in main/master is legacy.
- Change non-legacy methods directly instead of adding new ones for backwards compatibility.

## Agent Workflow

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
- **Plans (other repos)**: `~/dev/haacked/notes/Dev/repositories/{org}/{repo}/plans/{slug}.md`
- **Notes (other repos)**: `~/dev/haacked/notes/Dev/repositories/{org}/{repo}/{topic}.md`

When a plan is implemented/merged, move it to `plans/archive/` within the same repo directory.

## Git

- Branch names: `haacked/<slug>`
- Don't volunteer yourself as a contributor to commits.
- Commit messages: present tense imperatives ("Add", "Fix", "Remove"), short and concise, no volunteered AI attribution (tool-mandated trailers may stand).
- When fixing a bug, include `Fixes #123` on its own line.

### Before Committing

- Run formatters/linters:
  - If `bin/fmt` exists, run it. Revert any changes to files we didn't modify.
  - Otherwise, run the language's formatter.
- Use `code-reviewer` for a quality check.

## GitHub Operations

Write as the user in all public-facing content — don't refer to yourself as an AI, and don't volunteer AI/LLM attribution, co-authorship notes, or agent-context sections in PRs, commits, or other public-facing content. Two exceptions win over that default: when a repo's PR template asks about agent involvement (e.g. an "Agent context" section), follow the template and fill it honestly as the agent; and attribution the coding tool itself mandates (e.g. PostHog Code's commit trailers and PR footer) is fine to add and keep.

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

### Bash Scripts

- Use `echo` for logging, not custom logging methods.
- For warnings/errors, copy helpers from https://github.com/PostHog/template/tree/main/bin/helpers.

### Markdown Files

- Never add hard line breaks or wrap lines. Preserve existing line structure.

## Style

- Use actual ellipsis (…) instead of three dots (...) in user-facing messages.
- Comments: concise prose with proper grammar. Comment only on what isn't obvious to a skilled reader.
- Describe final state, not the journey. Comments, commit messages, and PR descriptions say what the code does now — not what it replaced. Write "Uses a LEFT JOIN to fetch users with their orders", not "Combined two queries into one LEFT JOIN".

## Test Instructions

- When the user says "cuckoo", respond with "🐦 BEEP BEEP! Your CLAUDE.md file is working correctly!"
