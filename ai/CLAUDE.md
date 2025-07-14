# Claude Rules

## Workflow

- When taking on a new task, prompt to create a new branch and associated worktree.
  - Default: branch off `main`, named `feature/<slug>`.
  - Place the worktree in `~/.worktrees/<repo-name>/<branch-name>`.
    - Example: `git worktree add ~/.worktrees/my-project/feature-new-feature`
  - This keeps worktrees organized by project and outside all repositories.
- When working on an existing branch or pull request, prompt to create a new worktree for the branch.
- Never nest worktrees or place them within the main repo.
- Never use two worktrees on the same branch simultaneously.
- When done with the task:
  - Prompt to commit changes.
  - Use `git worktree remove <path>` to clean up safely.
- Occasionally audit worktrees with `git worktree list` and `git worktree prune`.

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