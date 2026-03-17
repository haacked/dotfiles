---
name: commit
description: Commit staged/unstaged changes with a well-crafted commit message.
argument-hint: "[--force] [<message hint>]"
model: haiku
---

# Commit

Commit changes with a message that follows project conventions.

`force` = true if `--force` is present in the arguments.
`message_hint` = remaining text after stripping `--force`, or empty string if none was given.

Example invocations:

- `/commit`
- `/commit Fix race condition in job queue`
- `/commit Add webhook retry support`
- `/commit --force`
- `/commit --force Fix race condition in job queue`

## Steps

### 1. Gather Git Context

Run in parallel:

```bash
git status                          # staged, unstaged, and untracked files
git diff HEAD                       # all uncommitted changes (staged + unstaged)
git log --oneline -10               # recent commits for message style reference
```

If `git diff HEAD` fails (no commits yet), run `git diff --cached` instead.

If `git status` shows a clean working tree with nothing staged, tell the user there is nothing to commit and stop.

### 2. Compose Commit Message

**Format:**

```
<imperative subject line, ≤72 characters>

[optional body — include only when the subject alone does not tell a reader
 why the change exists; omit entirely for small, obvious changes]

[Fixes #<issue> — include only when this commit closes a GitHub issue]
```

**Subject line rules:**

- Start with an imperative verb: "Add", "Fix", "Remove", "Update", "Refactor", etc.
- No period at the end
- Describe the final state — what the code does now, not what it replaced
- If `message_hint` is non-empty, use it verbatim as the subject line (trim whitespace; do not rephrase)

**Attribution rules (non-negotiable):**

- Never mention AI, Claude, or LLMs anywhere in the message
- Never add co-authorship lines

### 3. Show Preview and Confirm

If `force` is true, skip to Step 4 immediately — do not show a preview or ask for confirmation.

Otherwise, display the proposed commit exactly as shown below, then stop and wait for the user to reply:

```
Files to commit:
  staged:    <list, or "(none)">
  unstaged:  <list, or "(none)">
  untracked: <list, or "(none)">

Commit message:
  <subject line>

  <body, if any>

  <Fixes line, if any>
```

Ask: "Commit with this message? Reply yes to confirm, or describe any changes."

Do not proceed until the user replies. If the user requests changes, update the message and show the full preview again before asking once more.

### 4. Commit

Stage specific files by name. Do not use `git add -A` or `git add .`.

Use absolute paths in all bash commands.

```bash
git add <absolute path to each file>
git commit -m "$(cat <<'EOF'
<message>
EOF
)"
```

### 5. Report Result

On success, show the short commit hash and subject line. On failure, show the full error output and stop.
