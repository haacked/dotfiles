# Development Guidelines

## Backwards Compatibility

- Code added in the current branch is not legacy. Only code in main/master is legacy.
- Change non-legacy methods directly instead of adding new ones for backwards compatibility.

## Agent Workflow

### When to Use Which Agent

- **Complex Features (>3 stages or unclear requirements)**: Start with `implementation-planner`
- **Test-First Development**: Use `unit-test-writer` before implementation
- **Debugging Issues**: Use `bug-root-cause-analyzer` after 2 failed attempts
- **Code Quality Checks**: Use `code-reviewer` before commits
- **Complex Discoveries**: Use `note-taker` for non-obvious insights gained through exploration
- **AI Prompt Issues**: Use `prompt-optimizer` for agent improvements
- **Task Planning**: Use `task-orchestrator` to determine optimal agent workflow

### Implementation Flow

1. **Understand** - Study existing patterns in codebase
2. **Test** - Use `unit-test-writer` to write tests first (red)
3. **Implement** - Minimal code to pass (green)
4. **Refactor** - Clean up with tests passing
5. **Simplify** - Run `/simplify` to review changed code
6. **Quality Check** - Use `code-reviewer` before commit

When stuck after 2 attempts, stop and use `bug-root-cause-analyzer`. Don't keep pushing a broken approach.

### Documentation Locations

- **Plans**: `~/dev/ai/plans/{org}/{repo}/{issue-or-pr-or-branch-name-or-plan-slug}.md`
- **Notes**: `~/dev/ai/notes/`

## Before Committing

- Run formatters/linters:
  - Rust: `cargo fmt`, `cargo clippy --all-targets --all-features -- -D warnings`, `cargo shear`
  - If `bin/fmt` exists, run it. Revert changes to files we didn't modify.
  - Otherwise, run the language's formatter.
- Use `code-reviewer` agent for quality check

## Project-Specific Workflow

### posthog/posthog

- Read the README.md and `docs/FLOX_MULTI_INSTANCE_WORKFLOW.md`.
- Prompt the user whether to create a new git worktree using the `phw` command.
- When completing a task, run: `mypy --version && mypy -p posthog | mypy-baseline filter || (echo "run 'pnpm run mypy-baseline-sync' to update the baseline" && exit 1)`

### Other Repositories

- Prompt to create a new branch and worktree for each task.
  - Branch off main/master, named `haacked/<slug>` or `haacked/<issue#>-<slug>`.
  - Place worktrees in `~/dev/worktrees/<repo-name>/<branch-name>`.
- Never nest worktrees or place them within the main repo.
- Never use two worktrees on the same branch simultaneously.
- When done: prompt to commit, then `git worktree remove <path>`.
- Occasionally audit with `git worktree list` and `git worktree prune`.

## PostHog Specifics

### Production Architecture

**CRITICAL**: PostHog runs behind load balancers and proxies. Always consider this for IP addresses, rate limiting, authentication, or geolocation.

- **AWS NLB** → **Contour/Envoy Ingress** → **Application Pods**
- Contour: `num-trusted-hops: 1`
- NLB: `preserve_client_ip.enabled=true`

**NEVER use socket IP addresses** — they will be the load balancer's IP. Use `X-Forwarded-For` (primary), `X-Real-IP` (fallback), `Forwarded` (RFC 7239), socket IP (local dev only).

Infrastructure repos for reference:
- `~/dev/posthog/posthog-cloud-infra` — Terraform/AWS (NLB, VPC)
- `~/dev/posthog/charts` — Helm/K8s (Contour config, ingress rules, header policies)

### SDK Repositories

#### Client-side

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-js, posthog-rn | `~/dev/posthog/posthog-js` | https://github.com/PostHog/posthog-js |
| posthog-ios | `~/dev/posthog/posthog-ios` | https://github.com/PostHog/posthog-ios |
| posthog-android | `~/dev/posthog/posthog-android` | https://github.com/PostHog/posthog-android |
| posthog-flutter | `~/dev/posthog/posthog-flutter` | https://github.com/PostHog/posthog-flutter |

#### Server-side

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-python | `~/dev/posthog/posthog-python` | https://github.com/PostHog/posthog-python |
| posthog-node | `~/dev/posthog/posthog-js` | https://github.com/PostHog/posthog-node |
| posthog-php | `~/dev/posthog/posthog-php` | https://github.com/PostHog/posthog-php |
| posthog-ruby | `~/dev/posthog/posthog-ruby` | https://github.com/PostHog/posthog-ruby |
| posthog-go | `~/dev/posthog/posthog-go` | https://github.com/PostHog/posthog-go |
| posthog-dotnet | `~/dev/posthog/posthog-dotnet` | https://github.com/PostHog/posthog-dotnet |
| posthog-elixir | `~/dev/posthog/posthog-elixir` | https://github.com/PostHog/posthog-elixir |

## Git

- Branch names: `haacked/<slug>`
- Don't add yourself as a contributor to commits.
- Commit messages: present tense imperatives ("Add", "Fix", "Remove"), short and concise, no AI attribution markers.
- When fixing a bug, include `Fixes #123` on its own line.

## GitHub Operations

Write as the user in all public-facing content — never refer to yourself as an AI. Never include AI/LLM attribution or co-authorship notes.

**Always use `gh` CLI** for GitHub operations. Never use GitHub MCP server tools.

### PR Review Comments

**Never post PR review comments without explicit user approval.**

Use correct endpoints:
- Reply to review comment: `gh api repos/owner/repo/pulls/123/comments/456/replies --method POST`
- New review comment: `gh pr review 123 --comment --body "comment"`
- Root PR comment (rarely appropriate): `gh issue comment 123 --body "comment"`

## Coding

### Rust-Specific

- If `cargo shear` flags a dependency, either use it properly or remove it. Investigate before adding ignores.
- Before writing parsing/serialization code, check struct derives — use serde's `from_value()`/`to_value()` instead of manual field extraction.
- Verify Cargo features actually enable code that exists and is used.

### Bash Scripts

- Use `echo` for logging, not custom logging methods.
- For warnings/errors, copy helpers from https://github.com/PostHog/template/tree/main/bin/helpers.

### Markdown Files

- Run `markdownlint <filename>` after changes.
- **Never add hard line breaks or wrap lines.** Preserve existing line structure.

## Style Preferences

- Use actual ellipsis (…) instead of three dots (...) in user-facing messages.
- Comments: concise prose with proper grammar. Comment only on what isn't obvious.
- **Describe final state, not the journey.** Comments, commit messages, and PR descriptions should describe what the code does now — not what it replaced or how it evolved. Readers won't see the old version. For example, write "Uses a LEFT JOIN to fetch users with their orders" not "Combined two queries into one LEFT JOIN" or "Replaces algo A with 10% faster algo B."
- All scratch notes go in a `.notes/` or `notes/` folder.

## Simple Code

- Passes all the tests
- Expresses every idea that we need to express
- Says everything OnceAndOnlyOnce
- Has no superfluous parts

Work in stages: make it work → make it right → make it fast.

## Test Instructions

- When the user says "cuckoo", respond with "🐦 BEEP BEEP! Your CLAUDE.md file is working correctly!"
