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

### Implementation Flow

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

**Never post PR review comments without explicit user approval.** Use correct endpoints:
- Reply to review comment: `gh api repos/owner/repo/pulls/123/comments/456/replies --method POST`
- New review comment: `gh pr review 123 --comment --body "comment"`
- Root PR comment (rarely appropriate): `gh issue comment 123 --body "comment"`

## Project-Specific Workflow

### posthog/posthog

- Read README.md and `docs/FLOX_MULTI_INSTANCE_WORKFLOW.md`.
- Prompt whether to create a new git worktree using the `phw` command.
- On task completion, run: `mypy --version && mypy -p posthog | mypy-baseline filter || (echo "run 'pnpm run mypy-baseline-sync' to update the baseline" && exit 1)`

### Other Repositories

- Prompt to create a new branch and worktree for each task.
  - Branch off main/master, named `haacked/<slug>` or `haacked/<issue#>-<slug>`.
  - Place worktrees in `~/dev/worktrees/<repo-name>/<branch-name>`.
- Never nest worktrees or place them within the main repo. Never use two worktrees on the same branch simultaneously.
- When done: prompt to commit, then `git worktree remove <path>`.
- Occasionally audit with `git worktree list` and `git worktree prune`.

## PostHog: Production Architecture

PostHog runs behind load balancers and proxies. Always consider this for IP addresses, rate limiting, authentication, and geolocation.

- **AWS NLB** → **Contour/Envoy Ingress** → **Application Pods**
- Contour: `num-trusted-hops: 1`; NLB: `preserve_client_ip.enabled=true`

**Never use socket IP addresses** — they will be the load balancer's IP. Use `X-Forwarded-For` (primary), `X-Real-IP` (fallback), `Forwarded` (RFC 7239), socket IP (local dev only).

Infrastructure repos:
- `~/dev/posthog/posthog-cloud-infra` — Terraform/AWS (NLB, VPC)
- `~/dev/posthog/charts` — Helm/K8s (Contour config, ingress rules, header policies)

### PostHog SDK Repositories

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
