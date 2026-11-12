---
name: spawn-task
description: Start a task in a new git worktree as its own Switchboard session. Creates the worktree and session with `sb new` (or reuses an existing branch's worktree through tree-me), writes a self-contained brief from this conversation, and starts claude on the brief. Use when the user asks to spin work off into a new worktree or session, says "use tree-me to create a worktree", "start a session on this", or runs /spawn-task.
argument-hint: "[<task>] [--stack] [--existing <branch|PR>] [--account <dir>] [--plan|--go]"
---

# /spawn-task

Starts a separate Claude session on a task. The session runs in its own worktree as a Switchboard session, which appears in `sb ls` and the Switchboard app. This session stays where it is: do not enter the new worktree, and do not do the task here.

When this session runs under Switchboard (`SB_SESSION_ID` is set), the new session is its child: Switchboard tells this session when the child needs attention, opens a PR, or finishes. From a plain terminal, the new session has no parent.

`scripts/spawn-task.sh` does the mechanical steps. This skill decides what goes into them: which repo, which branch and base, and what the brief says.

## Arguments

- `<task>`: what the new session should do. Without it, use the task the conversation has settled on. If the conversation names several candidates and the user did not say which, ask.
- `--stack`: base the new branch on the current branch instead of the remote default branch.
- `--existing <branch|PR>`: work on a branch or PR that already exists, reusing its worktree when it has one.
- `--account <dir>`: the Claude config directory the session runs under, such as `~/claude-work`. Pass it when the user names an account or an email, and map the email to its config directory first. Without it, Switchboard runs the child under this session's account, or under its active account from a plain terminal.
- `--plan`: ask the session to write a plan and wait for approval before it edits a file. `sb new` has no plan mode, so the request lives only in the prompt and nothing enforces it.
- `--go`: start the session with `/go`, using the brief as its plan.

Every new session starts in auto permission mode unless Switchboard's `autoMode` setting is false.

Users usually say these in words ("stack it on this one", "run /go on it"). Treat those the same as the flags.

When the user asks for several tasks, do Steps 1 to 4 once per task.

## Step 1: Pick the repo, branch, and base

- **Repo**: the repository the change belongs in. That is usually the current one, and `--repo .` works from any of its worktrees. For another repository, find its main checkout with `sb repo`, or look under `~/dev/<org>/<repo>`.
- **Branch**: `haacked/<slug>`, where the slug is two to five kebab-case words naming the change. For `--existing`, pass its branch name, PR number, or PR URL instead of `--branch`.
- **Base**: leave it out, and the script fetches and starts from the remote default branch. Stack on the current branch (`--base <current-branch>`) only when the user asks or when the task needs commits that branch has not merged.

## Step 2: Write the brief

The new session sees nothing of this conversation. The brief is its only context, so write it to stand alone. Write it to a file in your scratchpad directory, which stays until the task ends. `--go` passes the file's path to `/go`, so do not use a temp file you delete.

Include:

1. **Goal**: what to change and what done looks like, in one or two sentences.
2. **Context**: what this conversation already established. Give links (issue, PR, Slack thread), file paths with line numbers, findings, decisions the user made, and approaches already ruled out, so the new session does not repeat the work. Name the plan file when one exists.
3. **Where it runs**: the branch and its base, and for a stack, what the parent branch changes.
4. **Constraints**: the scope, what not to touch, and any rules the user stated for this task.
5. **Finish**: what to do when the work is done. Default to "Commit locally, then stop and ask before pushing or opening a PR." Use the user's instruction instead when they gave one. With `--go`, `/go` pushes and opens the PR itself, so leave this out.

Do not tell the new session to create a worktree or branch. It already runs in one.

## Step 3: Run the script

```bash
scripts/spawn-task.sh --repo <path> --branch haacked/<slug> [--base <ref>] --brief <file> [--title <short name>] [--account <dir>] [--plan | --go]
scripts/spawn-task.sh --repo <path> --existing <branch|PR> --brief <file> [...]
```

How the options reach `sb new`:

- With `--branch`, `sb new` creates the branch and its worktree and starts claude in one step, so the brief itself is the session's first prompt. `--go` instead passes `/go --plan-file <absolute path of the brief file>`.
- `--existing` finds the worktree with `tree-me switch`, copies the brief to `.notes/brief.md` there, and runs `sb new` in that folder with a prompt that points at the brief, or `/go --plan-file .notes/brief.md` with `--go`.
- `--title` sets the session's name. It defaults to the branch name after its last slash, or for `--existing` to the worktree's folder name.
- `sb new` puts the worktree at `~/dev/worktrees/<name of the repo's main checkout folder>/<branch>`. tree-me names that folder after the origin URL instead. The two differ when the main checkout's folder name is not the repo name, such as `~/.dotfiles`, whose `sb new` worktrees land under `.dotfiles` rather than `dotfiles`.

Run it from this session's working directory. The script refuses to start a session in the worktree it runs from.

On success the script prints `session=`, `name=`, and `worktree=` lines. On failure:

| Message | What to do |
| --- | --- |
| `sb new failed` | Read the `sb` message above it. If the message says `sb new` created the branch, rerun with `--existing <branch>`, because rerunning with `--branch` fails on the branch it made. Otherwise no session was recorded, so fix the cause and rerun. If the service is down, tell the user. |
| `` `sb` is not on PATH `` | Switchboard is not installed here. Tell the user. |
| branch already exists, here or on origin | Pick a new slug. If the user meant that branch, rerun with `--existing`. |
| cannot reach origin | The script cannot check whether the branch name is taken. Tell the user and stop. |
| is the worktree this command runs in | The new session would share this session's checkout. Ask the user which branch to use. |
| ends with "Rerun with --existing … to finish" | The worktree exists, but no session started. If you can fix the cause, such as a blocked sandbox, do so and run that rerun. Otherwise tell the user the worktree path and stop. Do not delete the worktree or start over under a new slug. |

## Step 4: Report

Tell the user, in two or three lines: the session's name (`sb get <session id>` shows it, using the printed `session=` id, because names can repeat), the worktree path, and the branch with its base. Under Switchboard, add that the session is this one's child, so its progress is reported here. Do not repeat the brief. Say where it is: the session's first prompt, or `.notes/brief.md` for `--existing`. Mention that `--plan` was only requested in the prompt when it was used.
