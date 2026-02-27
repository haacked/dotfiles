---
name: rebase
description: Rebase the current branch with AI-powered conflict resolution, including stacked PR duplicate detection and mergiraf structural merging.
argument-hint: [<target>|--abort]
---

# Rebase with AI Conflict Resolution

Rebase the current branch onto a target, with intelligent conflict resolution for lock files, migrations, mergiraf-supported languages, and stacked PR duplicates.

## Arguments (parsed from user input)

- No arguments: auto-detect state. If mid-rebase, resolve conflicts; otherwise rebase onto the default branch.
- `<target>`: branch name to rebase onto (e.g., `main`, `develop`). Fetches and rebases onto `origin/<target>`.
- `--abort`: abort the current rebase.

Example invocations:

- `/rebase` -- rebase onto default branch, or resume conflict resolution if mid-rebase
- `/rebase develop` -- rebase onto `origin/develop`
- `/rebase --abort` -- abort current rebase

## Your Task

### Step 1: Detect State

Run the status script:

```bash
~/.claude/skills/rebase/scripts/rebase-status.sh
```

This outputs tab-separated: `state\tcurrent\ttotal\ttarget\tbranch`

Parse the fields:

- `state`: one of `idle`, `conflict`, `in-progress`
- `current`: current step number (empty when idle)
- `total`: total steps (empty when idle)
- `target`: the rebase target ref (empty when idle)
- `branch`: the branch being rebased

**Route based on state and arguments:**

| State | Argument | Action |
| --- | --- | --- |
| idle | `--abort` | Report "No rebase in progress" and stop |
| idle | none or `<target>` | Go to Step 2 (Start Rebase) |
| conflict | `--abort` | Run `git rebase --abort`, report, and stop |
| conflict | any | Go to Step 3 (Conflict Resolution Loop) |
| in-progress | `--abort` | Run `git rebase --abort`, report, and stop |
| in-progress | any | Run `git rebase --continue`, then re-check state |

When aborting, report: "Rebase aborted. Back on `<branch>`."

### Step 2: Start Rebase

1. Determine the target branch:
   - If the user provided `<target>`, use that
   - Otherwise: `git symbolic-ref refs/remotes/origin/HEAD | sed 's@^refs/remotes/origin/@@'`
2. Fetch: `git fetch origin`
3. Count commits: `git rev-list --count origin/<target>..HEAD`
4. Report: "Rebasing `<branch>` (N commits) onto `origin/<target>`"
5. Run: `git rebase --update-refs origin/<target>`
   - `--update-refs` keeps stacked branch pointers updated automatically
6. If the rebase completes cleanly, go to Step 5 (Post-Rebase)
7. If the rebase stops with conflicts, go to Step 3

### Step 3: Conflict Resolution Loop

For each rebase step that has conflicts, resolve them and continue. Repeat until the rebase completes.

#### 3a: Categorize Conflicts

Run:

```bash
~/.claude/skills/rebase/scripts/categorize-conflicts.sh
```

This outputs tab-separated lines: `category\tfile_path`

Report the categorization to the user, e.g.:

> **Conflicts in step 3/12:**
>
> - 1 lockfile: `package-lock.json`
> - 2 mergiraf: `src/app.ts`, `src/utils.ts`
> - 1 migration: `migrations/0042_add_column.py`

#### 3b: Resolve by Category

Process conflicts in this order:

**1. Lock files (`lockfile`)**

Accept theirs and stage:

```bash
git checkout --theirs <file> && git add <file>
```

Track which lock files need regeneration (handled after all conflicts in the current step are resolved).

**2. Migrations (`migration`)**

Do not auto-resolve. Ask the user how to proceed for each migration file. Common options:

- Accept theirs (the merged version from the target branch)
- Accept ours (the version from the feature branch)
- Manual resolution with your guidance

**3. Mergiraf-supported files (`mergiraf`)**

Run mergiraf as a second pass (it may have already run as a merge driver, but sometimes conflicts remain):

```bash
mergiraf solve <file> --compact
```

After running mergiraf, read the file and check for remaining conflict markers (`<<<<<<<`). If conflict markers remain, proceed with AI analysis (see Step 3c).

If mergiraf fully resolves the file (no markers remain), stage it:

```bash
git add <file>
```

**4. Other files (`other`)**

Read the file contents and resolve using AI analysis (see Step 3c).

#### 3c: AI Conflict Analysis

For conflicts that remain after mergiraf (or for `other` category files), read the file and analyze each conflict hunk. Git is configured for diff3 style, so conflict markers look like:

```text
<<<<<<< HEAD
[head_code]
||||||| base
[base_code]
=======
[incoming_code]
>>>>>>> commit message
```

**Stacked PR duplicate detection:**

When the base section is empty or contains substantially less code than both sides, this often indicates a stacked PR scenario where a sub-PR was merged, duplicating code that also exists in the feature branch.

| Base | HEAD vs Incoming | Action |
| --- | --- | --- |
| Empty or missing code | >95% similar (after normalizing whitespace) | **Auto-resolve**: keep HEAD version, report to user |
| Empty or missing code | 70-95% similar | **Ask user**: show both versions side-by-side, explain likely stacked PR context |
| Empty or missing code | <70% similar | **Ask user**: true divergence, present both options |
| Present | Both modified | **Ask user**: standard conflict, present analysis |

For auto-resolutions, always report clearly what was resolved and why:

> Auto-resolved `src/feature.ts` hunk at line 42: stacked PR duplicate (HEAD and incoming are 98% similar with empty base). Kept HEAD version.

For all other cases, present the conflict to the user with your analysis and recommendation, then apply their choice.

After resolving all hunks in a file, stage it: `git add <file>`

#### 3d: Continue Rebase

After all conflicts in the current step are resolved and staged:

1. If lock files were resolved, regenerate them now:
   - `package-lock.json` or `pnpm-lock.yaml` -- `npm install` or `pnpm install`
   - `yarn.lock` -- `yarn install`
   - `Cargo.lock` -- `cargo generate-lockfile`
   - `poetry.lock` -- `poetry lock --no-update`
   - `Gemfile.lock` -- `bundle install`
   - `composer.lock` -- `composer install`
   - Stage the regenerated lock file: `git add <lockfile>`
2. Run: `git rebase --continue`
3. If the rebase stops with more conflicts, loop back to Step 3a
4. If the rebase completes, go to Step 5

### Step 4: (Reserved for future use)

### Step 5: Post-Rebase

After the rebase completes:

1. **Summary**: report total commits rebased, conflicts resolved (broken down by auto-resolved vs user-resolved), and lock files regenerated
2. **Updated refs**: check for branches updated by `--update-refs`:

   ```bash
   git log --oneline --decorate | head -20
   ```

   Report any `(updated-ref: ...)` annotations.

3. **Rerere**: if git rerere applied any recorded resolutions during the rebase, note that in the summary
4. **Force push**: ask the user whether to force push:

   > Ready to force push? This will run: `git push --force-with-lease --force-if-includes origin +<branch>`

   Only push if the user confirms.

## Integration Notes

- **mergiraf** is installed and configured as a git merge driver. It runs automatically during rebase for supported files. This skill runs `mergiraf solve` as a second pass for any remaining conflicts.
- **rerere** is enabled globally. Git automatically records and replays conflict resolutions.
- **`--update-refs`** keeps stacked branch pointers updated during rebase, avoiding the need to manually rebase each branch in a stack.
- This skill follows the same conventions as the existing git aliases `re`, `rbc`, `rba`, and `fp`.
