# Development Guidelines

## Backwards Compatibility

- Code added in the current branch is not legacy. Only code in main/master is legacy.
- Change non-legacy methods directly instead of adding new ones for backwards compatibility.

## Agent Workflow

### Skill script paths

A skill's own scripts and references are written relative to the skill's directory, as `scripts/foo.sh` rather than an absolute path. Resolve them against the base directory the harness gives you when it invokes the skill. Paths that start with `~/.dotfiles/` are the exception and mean what they say: they point at a repo binary or another skill, so that skill needs this repo cloned at `~/.dotfiles`.

### Skill model tiers

- Skills may declare `metadata.execution-tier` as `fast`, `balanced`, `deep`, or `inherit`.
- Claude uses the native `model` field in the same skill.
- In Codex, the tier is visible once you open a skill's `SKILL.md`. Delegate `fast`, `balanced`, and `deep` skills to the matching `skill-runner-fast`, `skill-runner-balanced`, or `skill-runner-deep` custom agent. `inherit` and skills without a tier run in the current agent.

### Implementation Flow

If arriving from an approved Plan Mode plan, invoke the `go` skill with `--plan-file <path>` instead of the manual steps below. It runs plan-reuse, implementation, simplify, commit, PR, and both review loops automatically.

1. Study existing patterns in the codebase
2. `unit-test-writer` writes tests first (red)
3. Implement minimal code to pass (green)
4. Refactor with tests passing
5. Run the `simplify` skill to review changed code, then `comment-cleanup` over the result
6. `code-reviewer` before committing

After 2 failed attempts, stop and use `bug-root-cause-analyzer`. Don't keep pushing a broken approach.

### Documentation Locations

- **Plans (PostHog repos)**: `~/dev/haacked/notes/PostHog/repositories/{repo}/plans/{slug}.md`
- **Notes (PostHog repos)**: `~/dev/haacked/notes/PostHog/repositories/{repo}/{slug}.md`
- **Plans (other repos)**: `~/dev/haacked/notes/Dev/repositories/{org}/{repo}/plans/{slug}.md`
- **Notes (other repos)**: `~/dev/haacked/notes/Dev/repositories/{org}/{repo}/{slug}.md`

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

Write as the user in all public-facing content. Don't refer to yourself as an AI, and don't volunteer AI/LLM attribution, co-authorship notes, or agent-context sections in PRs, commits, or other public-facing content. Two exceptions win over that default: when a repo's PR template asks about agent involvement (e.g. an "Agent context" section), follow the template and fill it honestly as the agent; and attribution the coding tool itself mandates (e.g. PostHog Code's commit trailers and PR footer) is fine to add and keep.

**Always use `gh` CLI** for GitHub operations. Never use GitHub MCP server tools.

**Never post PR review comments without explicit user approval.** See the `github-pr-operations` skill for endpoint reference and thread-resolution commands.

## Project-Specific Workflow

### posthog/posthog

- **Never use `posthog-db` to investigate production issues.** It does not have prod data, so for prod investigations use the `metabase-prod-query` skill.
- **Never use socket IP addresses in PostHog services.** They're the load balancer's IP, so use `X-Forwarded-For` (primary), `X-Real-IP` (fallback), or `Forwarded` (RFC 7239).

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
- For warnings/errors, copy helpers from the [PostHog template](https://github.com/PostHog/template/tree/main/bin/helpers).

### Markdown Files

- Never add hard line breaks or wrap lines. Preserve existing line structure.

## Style

- Use actual ellipsis (…) instead of three dots (...) in user-facing messages.
- Comments: default to none. The code already shows how it works, so comment only on what isn't obvious to a skilled reader: a constraint, a deliberate deviation, a gotcha, a workaround. Never narrate the code, restate a name or signature inline, or mark the end of a block. Hold each to one sentence carrying one fact, in concise prose with proper grammar; a doc comment may also carry the contract a caller cannot see. The `comment-cleanup` skill enforces this over comments that already exist.
- Say what happens, not a phrase that stands for it. A phrase is a label when a reader who doesn't already know the mechanism can't say what changes state: "holds the batch" (holding does what to it?) against "the batch does not commit its offsets until the broker answers". Keep a term the codebase already uses in that sense; the test is whether you can find it there meaning the same thing. This sets the wording of a comment the rule above already justified; it never justifies one.
- Describe final state, not the journey. Comments, commit messages, and PR descriptions say what the code does now, not what it replaced. Write "Uses a LEFT JOIN to fetch users with their orders", not "Combined two queries into one LEFT JOIN".

## Communication

These rules govern every response, chat replies included. The `plain-writing` skill owns the full rule set; what follows is only what must hold when no skill runs.

- Lead with the answer, result, or decision.
- Describe concrete behavior instead of inventing labels, metaphors, or jargon.
- Never use an em dash or an en dash. Use a comma, colon, semicolon, parenthesis, or a second sentence.
- Start concise. Add detail only when it affects a decision or prevents a mistake.

Before writing a PR description, review comment, report, design doc, or a message sent on my behalf, apply `plain-writing`. Skip it for commit messages, code comments, and chat replies, and skip it when the active skill already applies `plain-writing` itself, as `create-pr` does. Code comments skip the full pass but not the naming rule under Style: don't leave a label the reader has to decode.

## Test Instructions

- When the user says "cuckoo", respond with "🐦 BEEP BEEP! Your AI instructions are working correctly!"
