---
name: squash
description: Squash all developer commits on the current branch into one. CI snapshot commits (authored by bots) are preserved in place and reported.
argument-hint: "[<message hint>]"
model: sonnet
---

# Squash

Squash all developer commits on the current branch into a single commit. CI snapshot commits are left untouched.

`message_hint` = any text after `/squash`, or empty string if none was given.

Example invocations:

- `/squash`
- `/squash Refactor authentication flow`

## Definitions

A **CI snapshot commit** is any commit whose author email contains `[bot]` (e.g. `github-actions[bot]@users.noreply.github.com`). Every other commit is a **developer commit**.

## Steps

### 1. Commit Working-Directory Changes

Check for uncommitted changes (staged, unstaged, or untracked):

```bash
git status --porcelain
```

If the output is non-empty, invoke the `commit` skill to commit everything before squashing. Wait for it to finish, then re-check `git status --porcelain` — it must be empty before proceeding. If the working tree is still dirty (e.g. the user declined to commit something), tell the user and **stop**.

If the output is empty, proceed.

### 2. Gather Context

```bash
BASE_BRANCH=$(bash "$HOME/.dotfiles/bin/lib/git-default-branch.sh")
MERGE_BASE=$(git merge-base HEAD "origin/$BASE_BRANCH")
git log "$MERGE_BASE"..HEAD --format="%H %ae %s"
```

If the helper is not available or `BASE_BRANCH` is empty, tell the user and **stop**.

The log output is **newest-first**. Record the full list in that order; you will need to reverse it when building a rebase todo (which is oldest-first).

### 3. Classify Commits

Split the commit list into two groups:

- **Developer commits** — author email does NOT contain `[bot]`
- **CI snapshot commits** — author email contains `[bot]`

**Stop conditions — report and exit without making any changes:**

- If there are zero developer commits, tell the user: "No developer commits to squash."
- If there is exactly one developer commit and zero CI snapshot commits, tell the user: "Only one developer commit — nothing to squash."

### 4. Compose the Squash Message

Write a present-tense imperative subject line (≤72 chars) that describes the final state of the developer changes. Base it on the developer commit messages and `message_hint` (if non-empty, use it verbatim as the subject line).

Never mention AI, Claude, or LLMs anywhere in the message. No co-authorship lines.

Hold this message — you will apply it after the squash.

### 5. Squash

Choose the path that matches your commit list:

---

#### Path A — No CI snapshot commits

```bash
git reset --soft "$MERGE_BASE"
git commit -m "<squash message from Step 4>"
```

---

#### Path B — CI snapshot commits are present

Use an interactive rebase with a custom sequence editor that reorders the todo so all developer commits come first (squashed together), followed by all CI snapshot commits (each preserved as-is).

**How a rebase todo file works:**

Git passes the path to the todo file as `$1` to `GIT_SEQUENCE_EDITOR`. The file contains one line per commit in oldest-first order. Each line is:

```
<action> <short-hash> <subject>
```

The default action for every line is `pick`. To squash a commit into the one above it, change `pick` to `fixup`. Lines beginning with `#` are comments and are ignored.

**What the reordered todo must look like:**

Given a branch with (oldest → newest):
- `abc1234` developer commit "Add login page"
- `def5678` snapshot commit "Update snapshots"
- `ghi9012` developer commit "Fix redirect"

The default todo git produces is:

```
pick abc1234 Add login page
pick def5678 Update snapshots
pick ghi9012 Fix redirect
```

The reordered todo you must produce is:

```
pick abc1234 Add login page
fixup ghi9012 Fix redirect
pick def5678 Update snapshots
```

Rule: the **first** developer commit (oldest) uses `pick`; every subsequent developer commit uses `fixup`. All CI snapshot commits follow, each using `pick`, in their original relative order.

**Implementation:**

Write the sequence editor script to `/tmp/squash-rebase-editor.sh` with exactly this logic:

```bash
#!/usr/bin/env bash
# $1 is the path to the rebase todo file written by git.
# We rewrite it: developer commits first (first=pick, rest=fixup),
# then CI snapshot commits (each as pick), preserving relative order
# within each group.

TODO="$1"

# Read non-comment lines
mapfile -t lines < <(grep -v '^#' "$TODO" | grep -v '^$')

dev_lines=()
bot_lines=()

for line in "${lines[@]}"; do
    hash=$(echo "$line" | awk '{print $2}')
    email=$(git log -1 --format="%ae" "$hash" 2>/dev/null)
    if [[ "$email" == *"[bot]"* ]]; then
        bot_lines+=("pick $hash $(echo "$line" | cut -d' ' -f3-)")
    else
        dev_lines+=("$line")
    fi
done

{
    first=1
    for line in "${dev_lines[@]}"; do
        hash=$(echo "$line" | awk '{print $2}')
        subject=$(echo "$line" | cut -d' ' -f3-)
        if [[ $first -eq 1 ]]; then
            echo "pick $hash $subject"
            first=0
        else
            echo "fixup $hash $subject"
        fi
    done
    for line in "${bot_lines[@]}"; do
        echo "$line"
    done
} > "$TODO"
```

Make the script executable, then run the rebase:

```bash
chmod +x /tmp/squash-rebase-editor.sh
GIT_SEQUENCE_EDITOR=/tmp/squash-rebase-editor.sh git rebase -i "$MERGE_BASE"
```

After the rebase completes, amend the squashed developer commit (now the first commit) to apply the squash message:

```bash
git commit --amend -m "<squash message from Step 4>"
```

---

### 6. Report

Show the final log:

```bash
git log --oneline "$MERGE_BASE"..HEAD
```

If any CI snapshot commits were preserved, list them:

> The following CI snapshot commits were not squashed:
> - `<short-hash>` `<subject>`
