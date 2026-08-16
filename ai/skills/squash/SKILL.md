---
name: squash
description: Squash each contributor's run of contiguous commits on the current branch into one, preserving authorship. CI snapshot commits (authored by bots) are preserved in place and reported.
argument-hint: "[--parent <ref>] [<message hint>]"
model: sonnet
---

# Squash

Squash the current branch's commits while preserving attribution. Each contributor's run of contiguous commits collapses into a single commit authored by that contributor. CI snapshot commits are left untouched.

`message_hint` = any text after `/squash` once a `--parent <ref>` flag (if present) is stripped, or empty string if none was given. `--parent <ref>` overrides base detection: only commits after `<ref>` are squashed.

Example invocations:

- `/squash`
- `/squash Refactor authentication flow`
- `/squash --parent origin/haacked/parent-branch`

## Definitions

- A **CI snapshot commit** is any commit whose author email contains `[bot]` (e.g. `github-actions[bot]@users.noreply.github.com`).
- A **developer commit** is every other commit.
- A **run** is a maximal sequence of developer commits by the same author email, uninterrupted by another human's commits. CI snapshot commits do NOT break a run; a developer commit by a different author does.

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
eval "$(bash "$HOME/.dotfiles/bin/lib/git-pr-base.sh")"   # append --parent <ref> if the user passed one
MERGE_BASE=$(git merge-base HEAD "$REF")
MY_EMAIL=$(git config user.email)
git log "$MERGE_BASE"..HEAD --format="%H %ae %s"
```

If the helper is not available, exits non-zero, or leaves `BASE` or `MERGE_BASE` empty, tell the user and **stop**. The helper resolves the base a PR from this branch targets (precedence documented in its header: an open PR's base first, then recorded stack parents, then the repo default branch), reports its pick on stderr, and exports `NOTES` — non-empty when detection degraded or ignored a recorded parent.

The log output is **newest-first**. Reverse it to get the oldest-first order used by every step below.

**Range safety.** Squashing past the true base rewrites other commits' history, so check two things before touching anything. First, if `NOTES` is non-empty, detection hit a problem (GitHub unreachable, a recorded parent ignored, a stacked base rewritten since this branch was cut): report `NOTES` and **stop and ask the user to confirm the range**. Second, when `BASE` differs from `DEFAULT`, this branch is stacked on another branch: report the base, how it was resolved (`SOURCE`, plus the PR number from `PR` when set), and the full commit list above before changing anything; if the commit list plausibly contains another branch's commits (more commits than this branch should have, or subjects belonging to other work), **stop and ask** as well.

### 3. Build the Plan

Walk the commits oldest-first and build an ordered **plan**: a list of items, where each item is either a **run** (author email + the run's commits, oldest-first) or a single **CI snapshot commit**. Maintain one open run and a pending list of snapshot commits:

- **CI snapshot commit**: if a run is open, append the commit to the pending list. Otherwise append it to the plan directly.
- **Developer commit with the same author email as the open run**: append it to the open run.
- **Any other developer commit**: close the open run (append the run to the plan, then append each pending snapshot to the plan in order, then clear the pending list). Open a new run containing this commit.

At the end, close the open run the same way.

**Validate**: every commit from Step 2 appears in the plan exactly once. If not, rebuild the plan before proceeding.

**Worked example.** Given (oldest → newest):

| Hash | Author | Subject |
| ---- | ------ | ------- |
| `a1` | `alice@x.com` | Add login page |
| `s1` | `renovate[bot]@x.com` | Update snapshots |
| `a2` | `alice@x.com` | Fix typo |
| `b1` | `bob@x.com` | Add logout |
| `b2` | `bob@x.com` | Address review |
| `s2` | `github-actions[bot]@x.com` | Update snapshots |

The plan is: run(`alice@x.com`: `a1`, `a2`) — `s1` does not break alice's run — then snapshot `s1`, run(`bob@x.com`: `b1`, `b2`), snapshot `s2`. Step 5's Path B shows the rebase todo this plan produces.

**Stop conditions — report and exit without making any changes:**

- If there are zero developer commits, tell the user: "No developer commits to squash."
- If no run contains more than one commit, tell the user: "Nothing to squash — every contributor's commits are already separate."

### 4. Compose the Squash Messages

For each run with two or more commits, write a subject line (≤72 chars) for that run's combined changes, based on that run's commit messages and following the commit-message conventions in CLAUDE.md. Runs with a single commit keep their original message.

If `message_hint` is non-empty, use it verbatim as the subject of the squashed run authored by `MY_EMAIL`. If multiple of your runs are being squashed, apply it to the one with the most commits and compose subjects for the rest. If none of your runs are being squashed, ignore the hint.

Number the squashed runs 1, 2, … in plan order and write each message to `/tmp/squash-msg-<n>.txt`.

### 5. Squash

Choose the path that matches your plan:

---

#### Path A — Single run, no CI snapshot commits, authored by you

If the plan is exactly one run, its author email equals `MY_EMAIL`, and there are no CI snapshot commits:

```bash
git reset --soft "$MERGE_BASE"
git commit -F /tmp/squash-msg-1.txt
```

---

#### Path B — Everything else

Use an interactive rebase whose todo file you author directly from the plan.

**Todo construction rules.** Process plan items in order, emitting one block per item:

- **Run**: `pick <full-hash> <subject>` for the first commit, then `fixup <full-hash> <subject>` for each remaining commit. If the run has two or more commits, follow with `exec git commit --amend -F /tmp/squash-msg-<n>.txt` (using the run's number from Step 4). `fixup` keeps the first commit's author, so the run stays attributed to its contributor; the `exec` line replaces the message while the squashed commit is `HEAD`.
- **CI snapshot commit**: `pick <full-hash> <subject>`.

For the worked example in Step 3, the todo is:

```text
pick a1 Add login page
fixup a2 Fix typo
exec git commit --amend -F /tmp/squash-msg-1.txt
pick s1 Update snapshots
pick b1 Add logout
fixup b2 Address review
exec git commit --amend -F /tmp/squash-msg-2.txt
pick s2 Update snapshots
```

Write the todo to `/tmp/squash-todo.txt`, then run the rebase with a sequence editor that replaces git's generated todo with yours:

```bash
OLD_HEAD=$(git rev-parse HEAD)
GIT_SEQUENCE_EDITOR="cp /tmp/squash-todo.txt" git rebase -i "$MERGE_BASE"
```

If the rebase stops with conflicts (most likely from a CI snapshot commit displaced past later commits in the same run), run `git rebase --abort`, tell the user which commit conflicted, and **stop**.

**Verify** the rewrite changed history but not content:

```bash
git diff --stat "$OLD_HEAD" HEAD
```

The output must be empty. If it is not, tell the user the squash produced a different tree, suggest `git reset --hard "$OLD_HEAD"` to restore the branch, and **stop**.

---

### 6. Report

Show the final log:

```bash
git log --oneline "$MERGE_BASE"..HEAD
```

Summarize what was squashed, one line per squashed run:

> - `alice@x.com`: 2 commits → 1
> - `bob@x.com`: 2 commits → 1

If any CI snapshot commits were preserved, list them:

> The following CI snapshot commits were not squashed:
>
> - `<short-hash>` `<subject>`
