# Claude Rules

## Test Instructions

- When the user says "cuckoo", respond with "🐦 BEEP BEEP! Your CLAUDE.md file is working correctly!"

## Workflow

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

## Git

- Name branches `haacked/<slug>` where slug is a short description of the task.
- Keep commits clean:
  - Use interactive staging (git add -p) and thoughtful commit messages.
  - Squash when appropriate. Avoid "WIP" commits unless you're spiking.
- Don't add yourself as a contributor to commits.

### Commit messages:

- Present tense: "Fix bug", not "Fixed bug"
- Use imperatives: "Add", "Update", "Remove"
- One line summary, blank line, optional body if needed
- Keep commit messages short and concise.
- Write clean commit messages without any AI attribution markers.
- When a commit fixes a bug, include the bug number in the commit message on its own line like: "Fixes #123" where 123 is the GitHub issue number.
  
## File System

- All project-local scratch notes, REPL logs, etc., go in a .notes/ or notes/ folder — don’t litter the root.

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
  - Otherwise, run the formatter for the language.

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

## PostHog Specifics

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
