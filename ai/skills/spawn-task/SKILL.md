---
name: spawn-task
description: Start a task in a new git worktree with its own Claude session in Supacode, or as a child session under Switchboard. Creates the worktree with tree-me (or `sb new`), writes a self-contained brief from this conversation, and starts claude on the brief. Use when the user asks to spin work off into a new worktree or session, says "use tree-me to create a worktree", "attach a Supacode session", "start a session on this", or runs /spawn-task.
argument-hint: "[<task>] [--stack] [--existing <branch|PR>] [--color <tint>] [--account <dir>] [--plan|--go]"
---

# /spawn-task

Starts a separate Claude session on a task. The session runs in its own worktree, in a background tab the user can switch to. Supacode pins that worktree only when the worktree this session runs in is pinned. This session stays where it is: do not enter the new worktree, and do not do the task here.

Under Switchboard (`SB_SESSION_ID` is set in this session's environment), the script starts the task with `sb new` instead of tree-me and Supacode. The new session is a child of this one: it appears in `sb ls`, and Switchboard tells this session when it needs attention, opens a PR, or finishes. Without `SB_SESSION_ID`, the Supacode flow below applies unchanged.

`scripts/spawn-task.sh` does the mechanical steps. This skill decides what goes into them: which repo, which branch and base, and what the brief says.

## Arguments

- `<task>`: what the new session should do. Without it, use the task the conversation has settled on. If the conversation names several candidates and the user did not say which, ask.
- `--stack`: base the new branch on the current branch instead of the remote default branch.
- `--existing <branch|PR>`: work on a branch or PR that already exists, reusing its worktree when it has one.
- `--color <tint>`: Supacode tint (not available under Switchboard, where the script refuses it): `red`, `orange`, `yellow`, `green`, `teal`, `blue`, `purple`, or `#RRGGBB[AA]`. Pass it only when the user asks for a tint or a standing rule in memory sets one for this kind of work. Map a color Supacode lacks to the nearest one or a hex value.
- `--account <dir>`: the Claude config directory the session runs under, such as `~/claude-work`. Claude's default config directory means its default account. Pass it when the user names an account or an email, and map the email to its config directory first. Without it, the session runs under this session's account.
- `--plan`: start the session in plan mode, for when the user wants a plan before any edits. Under Switchboard, `sb new` has no plan mode, so the prompt asks the session to plan and wait for approval. Nothing enforces that.
- `--go`: start the session with `/go`, using the brief as its plan.
- `--auto`: start the session in auto permission mode (`claude --permission-mode auto`). It combines with `--go` but not with `--plan`. Switchboard refuses it, because `sb new` cannot pass a permission mode.

Users usually say these in words ("stack it on this one", "teal tint", "run /go on it"). Treat those the same as the flags.

When the user asks for several tasks, do Steps 1 to 4 once per task.

## Step 1: Pick the repo, branch, and base

- **Repo**: the repository the change belongs in. That is usually the current one, and `--repo .` works from any of its worktrees. For another repository, find its main checkout (`supacode repo list` prints them percent-encoded, or look under `~/dev/<org>/<repo>`).
- **Branch**: `haacked/<slug>`, where the slug is two to five kebab-case words naming the change. For `--existing`, pass its branch name, PR number, or PR URL instead of `--branch`.
- **Base**: leave it out, and the script fetches and starts from the remote default branch. Stack on the current branch (`--base <current-branch>`) only when the user asks or when the task needs commits that branch has not merged.

## Step 2: Write the brief

The new session sees nothing of this conversation. The brief is its only context, so write it to stand alone. Write it to a file in your scratchpad directory (or a `mktemp` file). The script copies it to `.notes/brief.md` in the new worktree.

Include:

1. **Goal**: what to change and what done looks like, in one or two sentences.
2. **Context**: what this conversation already established. Give links (issue, PR, Slack thread), file paths with line numbers, findings, decisions the user made, and approaches already ruled out, so the new session does not repeat the work. Name the plan file when one exists.
3. **Where it runs**: the branch and its base, and for a stack, what the parent branch changes.
4. **Constraints**: the scope, what not to touch, and any rules the user stated for this task.
5. **Finish**: what to do when the work is done. Default to "Commit locally, then stop and ask before pushing or opening a PR." Use the user's instruction instead when they gave one. With `--go`, `/go` pushes and opens the PR itself, so leave this out.

Do not tell the new session to create a worktree or branch. It already runs in one.

## Step 3: Run the script

```bash
scripts/spawn-task.sh --repo <path> --branch haacked/<slug> [--base <ref>] --brief <file> [--color <tint>] [--title <short title>] [--account <dir>] [--plan | --go]
scripts/spawn-task.sh --repo <path> --existing <branch|PR> --brief <file> [...]
```

`--title` sets the tab title. It defaults to the worktree's folder name, so pass a short one only when that name is unclear.

The tab's `claude` runs on the same Claude account as this session: the script copies this session's `CLAUDE_CONFIG_DIR` into the tab's command when it is set.

Under Switchboard the options map to `sb new`:

- `--repo` is the folder, `--branch` and `--base` are `sb new --branch` and `--base`, and `--account` is `sb new --account`. Without `--account`, the child runs under this session's account.
- `--title` becomes the session's name. It defaults to the branch name after its last slash.
- The brief goes into the session's first prompt, because `sb new` creates the worktree and starts claude in one step. `--go` instead passes `/go --plan-file <absolute path of the brief file>`, so keep that file where it stays until the task ends (your scratchpad directory, not a temp file you delete).
- `--existing` finds the worktree with `tree-me switch`, copies the brief to `.notes/brief.md` there, and runs `sb new` in that folder.
- `--color` is refused. Rerun without it.
- `sb new` puts the worktree at `~/dev/worktrees/<name of the repo's main checkout folder>/<branch>`. tree-me names that folder after the origin URL instead. The two differ when the main checkout's folder name is not the repo name, such as `~/.dotfiles`, whose `sb new` worktrees land under `.dotfiles` rather than `dotfiles`.

Run it from this session's working directory. The script refuses to start a session in the worktree it runs from.

On success the script prints `worktree=`, `worktree_id=`, and `tab=` lines. Under Switchboard it prints `session=`, `name=`, and `worktree=` lines instead. On failure:

| Message | What to do |
| --- | --- |
| `sb new failed` | Read the `sb` message above it. If the message says `sb new` created the branch, rerun with `--existing <branch>`, because rerunning with `--branch` fails on the branch it made. Otherwise no session was recorded, so fix the cause and rerun. If `sb` is not on PATH or its service is down, tell the user. |
| `--color sets a Supacode tint` | Switchboard has no tint. Rerun without `--color`. |
| `supacode socket` failed | Supacode is not running, or a sandbox blocks its socket. If Supacode is running, run the script again with the sandbox disabled. |
| branch already exists, here or on origin | Pick a new slug. If the user meant that branch, rerun with `--existing`. |
| cannot reach origin | The script cannot check whether the branch name is taken. Tell the user and stop. |
| is the worktree this command runs in | The new session would share this session's checkout. Ask the user which branch to use. |
| ends with "Rerun with --existing … to finish" | The worktree exists, but no session started. If you can fix the cause, such as a blocked sandbox, do so and run that rerun. Otherwise tell the user the worktree path and stop. Do not delete the worktree or start over under a new slug. |

## Step 4: Report

Tell the user, in two or three lines: the worktree path, the branch and its base, and that the session is running in a background Supacode tab with the tint you set. Do not repeat the brief. Mention that it is at `.notes/brief.md` in the worktree.

Under Switchboard, say instead that the session appears in `sb ls` under its name (and `sb get <session id>` shows it, using the printed `session=` id, because names can repeat), that it has this session as its parent so Switchboard reports its progress here, and that there is no Supacode tab. Give the worktree path and the branch with its base. The brief is the session's first prompt (for `--existing`, `.notes/brief.md`). Mention any option that behaved differently: `--plan` was only requested in the prompt.
