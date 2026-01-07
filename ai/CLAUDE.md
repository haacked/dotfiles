# Development Guidelines

## Philosophy

### Core Beliefs

- **Incremental progress over big bangs** - Small changes that compile and pass tests
- **Learning from existing code** - Study and plan before implementing
- **Pragmatic over dogmatic** - Adapt to project reality
- **Clear intent over clever code** - Be boring and obvious

### Simplicity Means

- Single responsibility per function/class
- Avoid premature abstractions
- No clever tricks - choose the boring solution
- If you need to explain it, it's too complex

## Backwards compatibility

- If code was added in the current branch, it's not legacy code. Only code in the main (or master) branch is legacy code.
- If you need to change a method that's not legacy, you can change it instead of adding a new method and trying to maintain backwards compatibility.

## Agent Orchestration Framework

### When to Use Which Agent

- **Complex Features (>3 stages or unclear requirements)**: Start with `implementation-planner`
- **Test-First Development**: Use `unit-test-writer` before implementation
- **Debugging Issues**: Use `bug-root-cause-analyzer` after 2 failed attempts
- **Code Quality Checks**: Use `code-reviewer` before commits
- **Complex Discoveries**: Use `note-taker` for non-obvious insights gained through exploration
- **AI Prompt Issues**: Use `prompt-optimizer` for agent improvements
- **Task Planning**: Use `task-orchestrator` to determine optimal agent workflow

### Workflow Integration Patterns

#### Pattern 1: New Feature Development

1. **Task Assessment** → `task-orchestrator` determines if `implementation-planner` needed
2. **Planning** → `implementation-planner` creates staged plan (if complex)
3. **Test Design** → `unit-test-writer` writes tests for current stage
4. **Implementation** → Write minimal code to pass tests
5. **Quality Check** → `code-reviewer` reviews before commit
6. **Documentation** → `note-taker` documents complex discoveries
7. Repeat steps 3-6 for each stage

#### Pattern 2: Bug Investigation

1. **Initial Debugging** → Try fixing yourself (max 2 attempts)
2. **Systematic Analysis** → `bug-root-cause-analyzer` investigates
3. **Fix Implementation** → Implement the identified solution
4. **Regression Prevention** → `unit-test-writer` adds tests to prevent recurrence
5. **Quality Check** → `code-reviewer` reviews fix and tests
6. **Knowledge Capture** → `note-taker` documents root cause if complex

#### Pattern 3: Code Quality Improvement

1. **Review** → `code-reviewer` identifies improvement opportunities
2. **Test Safety Net** → `unit-test-writer` ensures comprehensive test coverage
3. **Refactor** → Make improvements with tests passing
4. **Final Review** → `code-reviewer` validates improvements

## Process

### 1. Planning & Staging

When approaching a new repository, first read the README.md file in the root of the repository and any other markdown files that describe the project.

For complex tasks, the `implementation-planner` agent creates durable, structured plans following the template and process defined in the `implementation-planner` agent documentation.

### 2. Implementation Flow

1. **Understand** - Study existing patterns in codebase
2. **Test** - Use the `unit-test-writer` agent to write tests first (red)
3. **Implement** - Minimal code to pass (green)
4. **Refactor** - Clean up with tests passing
5. **Commit** - With clear message linking to plan

### 3. When Stuck (After 2 Attempts)

**CRITICAL**: Maximum 2 attempts per issue, then use `bug-root-cause-analyzer` agent.

The agent will systematically:

1. **Document what failed** - What you tried, error messages, suspected causes
2. **Research alternatives** - Find similar implementations and approaches
3. **Question fundamentals** - Evaluate abstraction level and problem breakdown
4. **Systematic investigation** - Use proven debugging methodologies

## Technical Standards

### Architecture Principles

- **Composition over inheritance** - Use dependency injection
- **Interfaces over singletons** - Enable testing and flexibility
- **Explicit over implicit** - Clear data flow and dependencies
- **Test-driven when possible** - Never disable tests, fix them

### Code Quality

- **Every commit must**:
  - Compile successfully
  - Pass all existing tests
  - Include tests for new functionality
  - Follow project formatting/linting

- **Before committing**:
  - Run formatters/linters
    - In a Rust codebase, run `cargo fmt`, `cargo clippy --all-targets --all-features -- -D warnings`, and `cargo shear` to check for issues.
    - If bin/fmt exists, run it.
    - Otherwise, run the formatter for the language.
  - Use `code-reviewer` agent for quality check
  - Ensure commit message explains "why"

### Error Handling

- Fail fast with descriptive messages
- Include context for debugging
- Handle errors at appropriate level
- Never silently swallow exceptions

## Decision Framework

For implementation decisions, refer to the decision framework in the `implementation-planner` agent documentation. Key factors include testability, maintainability, consistency, simplicity, and reversibility.

## Documentation Framework

### Project Planning

- **Location**: `~/dev/ai/plans/{org}/{repo}/{issue-or-pr-or-branch-name-or-plan-slug}.md`
- **Purpose**: Durable implementation plans for complex features
- **Owner**: `implementation-planner` agent
- **Lifecycle**: Permanent reference for architecture decisions and implementation history

### Knowledge Capture

- **Location**: `~/dev/ai/notes/`
- **Purpose**: Permanent knowledge about complex discoveries
- **Owner**: `note-taker` agent
- **Trigger**: Non-obvious behaviors, complex debugging insights

### Code Documentation

- **Location**: In-code comments and README updates
- **Purpose**: Explain WHY decisions were made
- **Owner**: Developer (guided by `code-reviewer`)

## Project Integration

### Learning the Codebase

- Find 3 similar features/components
- Identify common patterns and conventions
- Use same libraries/utilities when possible
- Follow existing test patterns

### Tooling

- Use project's existing build system
- Use project's test framework
- Use project's formatter/linter settings
- Don't introduce new tools without strong justification

## Quality Gates

### Definition of Done

- [ ] Tests written and passing and are not redundant or unnecessary
- [ ] Code is not dead or redundant and minimal to get the job done
- [ ] Code follows project conventions
- [ ] No linter/formatter warnings
- [ ] **All dependencies are used (no cargo-shear warnings in Rust)**
- [ ] **All Cargo features enable real functionality (Rust)**
- [ ] **No tool warnings ignored without strong justification**
- [ ] Commit messages are clear
- [ ] Implementation matches plan
- [ ] No TODOs without issue numbers

### Test Guidelines

- Test behavior, not implementation
- One assertion per test when possible
- Clear test names describing scenario
- Use existing test utilities/helpers
- Tests should be deterministic

## Important Reminders

**NEVER**:

- Use `--no-verify` to bypass commit hooks
- Disable tests instead of fixing them
- Commit code that doesn't compile
- Make assumptions - verify with existing code

**ALWAYS**:

- Commit working code incrementally
- Update implementation plan status as you progress through stages
- Learn from existing implementations
- Stop after 2 failed attempts and use `bug-root-cause-analyzer` agent
- Use the `code-reviewer` agent to review code before committing

## Project-specific Workflow

### posthog/posthog

When working on the https://github.com/PostHog/posthog repository, use the following workflow:

- Read the README.md file in the root of the repository and the https://github.com/PostHog/posthog/blob/master/docs/FLOX_MULTI_INSTANCE_WORKFLOW.md file.
- When taking on a new task, prompt the user whether they want to create a new git worktree using the `phw` command for the task.
- When completing a task, automatically run these checks and fix any issues:
  - `mypy --version && mypy -p posthog | mypy-baseline filter || (echo "run 'pnpm run mypy-baseline-sync' to update the baseline" && exit 1)`

When working on other repositories, use the following workflow:

- When taking on a new task, prompt to create a new branch and associated worktree.
  - Default: branch off the main branch (e.g. `main` or `master` depending on the repo), named `haacked/<slug>` or `haacked/<issue#>-<slug>` if the issue number is known.
  - Place the worktree in `~/dev/worktrees/<repo-name>/<branch-name>`.
    - Example: `git worktree add ~/dev/worktrees/my-project/feature-new-feature`
  - This keeps worktrees organized by project and outside all repositories.
- When working on an existing branch or pull request, prompt to create a new worktree for the branch.
- Never nest worktrees or place them within the main repo.
- Never use two worktrees on the same branch simultaneously.
- When done with the task:
  - Prompt to commit changes.
  - Use `git worktree remove <path>` to clean up safely.
- Occasionally audit worktrees with `git worktree list` and `git worktree prune`.
- Run `bin/fmt` to format the code if available.
  - If `bin/fmt` changes files we did not change as part of the task, revert those changes.

## PostHog Specifics

### Production Architecture

**CRITICAL**: PostHog production runs behind load balancers and proxies. Always consider this when implementing features that involve IP addresses, rate limiting, authentication, or geolocation.

#### Architecture Stack

- **AWS Network Load Balancer (NLB)** → **Contour/Envoy Ingress** → **Application Pods**
- Contour is configured with `num-trusted-hops: 1` to properly extract client IPs from headers
- NLB preserves client IPs via `preserve_client_ip.enabled=true`

#### Client IP Detection

**NEVER use socket IP addresses** - they will always be the load balancer's IP, not the client's IP.

**ALWAYS use X-Forwarded-For headers** in this precedence:
1. `X-Forwarded-For` (primary, set by load balancer/proxy)
2. `X-Real-IP` (fallback)
3. `Forwarded` (RFC 7239 standard format)
4. Socket IP (last resort only for local development)

**Common Libraries:**
- Rust: `tower_governor::key_extractor::SmartIpKeyExtractor`
- Look for similar "smart" IP extractors in other languages

#### Common Pitfalls to Avoid

- ❌ Using socket IP for rate limiting → all requests share one rate limit
- ❌ Using socket IP for authentication → security bypass
- ❌ Using socket IP for geolocation → all traffic appears from one location
- ❌ Implementing custom IP detection → reinventing the wheel, likely buggy

#### Infrastructure Repository References

For detailed production configuration, consult these repos:

- **`~/dev/posthog/posthog-cloud-infra`** - Terraform/AWS infrastructure
  - Contains: NLB config, VPC setup, load balancer settings
  - See: `README.md` for architecture diagram

- **`~/dev/posthog/charts`** - Helm charts and K8s deployment configs
  - Contains: Contour/Envoy configuration, ingress rules, header policies
  - Key files:
    - `argocd/contour/values/values.yaml` - num-trusted-hops config
    - `argocd/contour-ingress/values/values.prod-*.yaml` - routing and header policies
    - `docs/CONTOUR-GEOIP-README.md` - GeoIP and header handling

**When implementing networking/IP-related features**, check these repos to understand how headers flow through the infrastructure.

### SDK Repositories

PostHog has a lot of client SDKs. Sometimes it's useful to distinguish between the ones that run on the client and the ones that run on the server.

### Client-side SDKs

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-js, posthog-rn | `~/dev/posthog/posthog-js` | https://github.com/PostHog/posthog-js |
| posthog-ios | `~/dev/posthog/posthog-ios` | https://github.com/PostHog/posthog-ios |
| posthog-android | `~/dev/posthog/posthog-android` | https://github.com/PostHog/posthog-android |
| posthog-flutter | `~/dev/posthog/posthog-flutter` | https://github.com/PostHog/posthog-flutter |

### Server-side SDKs

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

- Name branches `haacked/<slug>` where slug is a short description of the task.
- Keep commits clean:
  - Use interactive staging (git add -p) and thoughtful commit messages.
  - Squash when appropriate. Avoid "WIP" commits unless you're spiking.
- Don't add yourself as a contributor to commits.

### Commit messages

- Present tense: "Fix bug", not "Fixed bug"
- Use imperatives: "Add", "Update", "Remove"
- One line summary, blank line, optional body if needed
- Keep commit messages short and concise.
- Write clean commit messages without any AI attribution markers.
- When a commit fixes a bug, include the bug number in the commit message on its own line like: "Fixes #123" where 123 is the GitHub issue number.

## GitHub Operations

### Tool Priority

**ALWAYS use `gh` CLI** (via Bash tool) for all GitHub operations - it's token-efficient, fully-featured, and has auto-approval configured.

**Tool Selection:**

- **Primary**: `gh` CLI for all GitHub operations (issues, PRs, repos, releases, etc.)
- **Documentation only**: WebFetch for public GitHub documentation URLs
- **Never**: GitHub MCP server tools (token-heavy, redundant with `gh` CLI)

### Common `gh` Commands

**Issues:**

```bash
gh issue list --repo owner/repo
gh issue view 123
gh issue create --title "Title" --body "Description"
gh issue close 123
gh issue comment 123 --body "Comment"
```

**Pull Requests:**

```bash
gh pr list --repo owner/repo
gh pr view 123
gh pr create --title "Title" --body "Description" --base main
gh pr checkout 123
gh pr merge 123
gh pr review 123 --approve
gh pr diff 123
gh pr checks 123
```

**Repository Operations:**

```bash
gh repo view owner/repo
gh repo clone owner/repo
gh repo fork owner/repo
gh api repos/owner/repo/path  # For any API endpoint
```

### When to Use Each Tool

- ✅ **`gh` CLI** - All GitHub operations (default choice)
  - Reason: Token-efficient, comprehensive API access
  - Read operations: Auto-approved (view, list, diff, status, checks)
  - Write operations: Require user approval (comment, review, create, merge)

- ✅ **WebFetch** - Public GitHub documentation only
  - Reason: Optimized for web content parsing
  - Example: Fetching GitHub guides, API documentation pages

- ❌ **GitHub MCP tools** - Don't use
  - Reason: Token-heavy, redundant functionality, less efficient than `gh` CLI

### IMPORTANT: PR Review Comments

**NEVER post PR review comments without explicit user approval.**

When posting review comments:
- **Always ask first** - Get user approval before posting any comment
- **Reply to existing threads** - If discussing an existing review comment, use `gh pr review --comment` with `--body` to reply in-thread, NOT `gh issue comment` which creates root-level comments
- **Use correct endpoints**:
  - Reply to review comment: `gh api repos/owner/repo/pulls/123/comments/456/replies --method POST`
  - New review comment: `gh pr review 123 --comment --body "comment"`
  - Root PR comment: `gh issue comment 123 --body "comment"` (rarely appropriate)

### Examples

**Reading PR details:**

```bash
# Good (token-efficient)
gh pr view 123 --json title,body,state,files

# Bad (unnecessary tokens)
# Using mcp__github__get_pull_request
```

**Creating issues:**

```bash
# Good
gh issue create --repo owner/repo --title "Bug" --body "Details"

# Bad
# Using mcp__github__create_issue
```

**Complex queries:**

```bash
# Use gh api for anything not covered by gh commands
gh api repos/owner/repo/pulls/123/comments
gh api graphql -f query='{ ... }'
```

## File System

- All project-local scratch notes, REPL logs, etc., go in a .notes/ or notes/ folder — don't litter the root.

## Coding

- When writing code, think like a principal engineer.
  - Focus on code correctness and maintainability.
  - Bias for simplicity: Prefer boring, maintainable solutions over clever ones.
  - Make sure the code is idiomatic and readable.
  - Write tests for changes and new code.
  - Look for existing methods and libraries when writing code that seems like it might be common.
  - Progress over polish: Make it work → make it right → make it fast.

- Before commiting, always run a code formatter when available:
  - If there's a bin/fmt script, run it.
  - In a Rust codebase, run `cargo fmt`, `cargo clippy`, and `cargo shear` to check for issues.
  - Otherwise, run the formatter for the language.

### Rust-Specific Guidelines

#### Dependency Management
- **Golden Rule**: If `cargo shear` wants to remove a dependency, either use it properly or remove it
- **Red Flag**: Any `cargo shear` ignore should trigger investigation - unused deps indicate design problems
- **Cargo Features**: Verify Cargo features actually enable code that exists and is used
- **Before adding ignores**: Always investigate why the dependency appears unused and ensure it's actually needed

#### Quality Checklist for Rust
1. Run `cargo fmt` - fix any formatting issues
2. Run `cargo clippy --all-targets --all-features -- -D warnings` - fix all warnings
3. **Run `cargo shear` - investigate any warnings before adding ignores**
4. **Verify new Cargo features enable real functionality**
5. **Check that new dependencies are actually imported/used in code**

- When writing human friendly messages, don't use three dots (...) for an ellipsis, use an actual ellipsis (…).

### Bash Scripts

- Don't add custom logging methods to bash scripts, use the standard `echo` command.
- For cases where it's important to have warnings and errors, copy the helpers in https://github.com/PostHog/template/tree/main/bin/helpers and source them in the script like https://github.com/PostHog/template/blob/main/bin/fmt does.

### Markdown Files

- When editing markdown files (.md, .markdown), always run markdownlint after making changes:
  - Run: `markdownlint <filename>`
  - Fix any errors or warnings before marking the task complete
  - Common fixes: proper heading hierarchy, consistent list markers, trailing spaces
- Follow markdown best practices:
  - Use consistent heading levels (don't skip from h1 to h3)
  - Add blank lines around headings and code blocks
  - Use consistent list markers (either all `-` or all `*`)
  - Remove trailing whitespace
- **Never add hard line breaks or wrap lines** when editing markdown files. Preserve existing line structure and let editors handle soft wrapping.

### Testing & Quality

- Always run tests before marking a task as complete.
- If tests fail, fix them before proceeding.
- When adding new functionality, write tests for it.
- Check for edge cases, error handling, and performance implications.
- Update relevant documentation when changing functionality.

### Dependency Philosophy

- Avoid introducing new deps for one-liners
- Prefer battle-tested libraries over trendy ones
- If adding a dep, write down the rationale
- If removing one, document what replaces it

## Comments

- Write eloquent, but concise commentary, and only comment on what is not obvious to a skilled programmer by reading the code. 
- Comments should contain proper grammar and punctuation and should be prose-like, rather than choppy partial sentences. A human reading your code's comments
should feel like they're reading a well-written professional whitepaper.
- Avoid dramatic and all-caps comments.
- IMPORTANT: Comment on the code as it is, not as it was.  For example, we recently combined two queries into one with a LEFT JOIN. Instead of saying "we combined two queries into one with a LEFT JOIN", describe what the query does now. The fact that it was combined is not important.

## Approach to work

I like "Simple code" that means:

- Passes all the tests.
- Expresses every idea that we need to express.
- Says everything OnceAndOnlyOnce.
- has no superfluous parts

These rules are in conflict with each other. Sometimes to express every idea we can't say everything only once. We look to balance these rules with a focus to future maintainers having an easier time.

Also... it means we work in three stages

- make it work
- make it right
- make it fast

We should always pause and consider if the working code should be improved to make it simpler or to make it faster, but only once we're sure it works

## Test Instructions

- When the user says "cuckoo", respond with "🐦 BEEP BEEP! Your CLAUDE.md file is working correctly!"
