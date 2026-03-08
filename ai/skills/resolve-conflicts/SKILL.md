---
name: resolve-conflicts
description: Resolve git conflicts with AI-powered analysis, including mergiraf structural merging, lock file handling, and stacked PR duplicate detection.
argument-hint: [--abort|--continue]
---

# Resolve Git Conflicts

Resolve conflicts from any git operation (rebase, merge, cherry-pick, revert) with intelligent handling of lock files, migrations, mergiraf-supported languages, and stacked PR duplicates.

## Arguments (parsed from user input)

- No arguments: detect context, resolve conflicts, continue the operation
- `--abort`: abort the current operation
- `--continue`: skip resolution, just run the appropriate continue command

Example invocations:

- `/resolve-conflicts` -- detect context, resolve conflicts, continue
- `/resolve-conflicts --abort` -- abort current rebase/merge/cherry-pick/revert
- `/resolve-conflicts --continue` -- continue without resolving (e.g., after manual edits)

## Your Task

### Step 1: Detect Context

Run the status script:

```bash
~/.claude/skills/resolve-conflicts/scripts/conflict-status.sh
```

This outputs tab-separated: `context\tprogress\tbranch`

Parse the fields:

- `context`: one of `rebase`, `merge`, `cherry-pick`, `revert`, `none`
- `progress`: `current/total` for rebase (e.g., `3/12`), empty for other contexts
- `branch`: the branch being worked on

Check for unmerged files:

```bash
git diff --name-only --diff-filter=U
```

**Route based on context, unmerged files, and arguments:**

| Context | Unmerged files? | Argument | Action |
| --- | --- | --- | --- |
| none | n/a | `--abort` | Report "No operation in progress" and stop |
| none | n/a | none/`--continue` | Report "No conflicts to resolve" and stop |
| active | n/a | `--abort` | Run `git <context> --abort`, report "Aborted `<context>`. Back on `<branch>`.", and stop |
| active | no | none/`--continue` | Run `git <context> --continue` (use `git commit --no-edit` for merge) |
| active | yes | `--continue` | Run `git <context> --continue` (use `git commit --no-edit` for merge) |
| active | yes | none | Go to Step 2 (Resolve Conflicts) |

### Step 2: Resolve Conflicts

#### 2a: Categorize Conflicts

Run:

```bash
~/.claude/skills/resolve-conflicts/scripts/categorize-conflicts.sh
```

This outputs tab-separated lines: `category\tfile_path`

Report the categorization to the user, e.g.:

> **Conflicts (rebase step 3/12):**
>
> - 1 lockfile: `package-lock.json`
> - 2 mergiraf: `src/app.ts`, `src/utils.ts`
> - 1 migration: `migrations/0042_add_column.py`

For non-rebase contexts, omit the step count:

> **Conflicts (merge):**

#### 2b: Resolve by Category

Process conflicts in this order:

**1. Lock files (`lockfile`)**

Accept theirs to clear the conflict markers. The content doesn't matter since Step 3 regenerates lock files from the resolved dependency manifest, but always choosing theirs keeps the behavior deterministic:

```bash
git checkout --theirs <file> && git add <file>
```

Track which lock files need regeneration (handled in Step 3).

**2. Migrations (`migration`)**

Do not auto-resolve. Ask the user how to proceed for each migration file. Common options:

- Accept theirs (`git checkout --theirs <file>`) — during merge/cherry-pick/revert this is the incoming branch; during rebase this is the commit being replayed (i.e., your branch)
- Accept ours (`git checkout --ours <file>`) — during merge/cherry-pick/revert this is the current branch; during rebase this is the upstream branch you're rebasing onto
- Manual resolution with your guidance

**3. Mergiraf-supported files (`mergiraf`)**

Run mergiraf as a second pass (it may have already run as a merge driver during the git operation itself, but sometimes conflicts remain). It is installed and configured as a git merge driver:

```bash
mergiraf solve -- <file> --compact
```

After running mergiraf, read the file and check for remaining conflict markers (`<<<<<<<`). If conflict markers remain, proceed with AI analysis (see Step 2c).

If mergiraf fully resolves the file (no markers remain), stage it:

```bash
git add <file>
```

**4. Other files (`other`)**

Read the file contents and resolve using AI analysis (see Step 2c).

#### 2c: AI Conflict Analysis

For conflicts that remain after mergiraf (or for `other` category files), read the file and analyze each conflict hunk. Conflict markers may appear in diff3 style (with a base section) or standard style (without). Handle both:

diff3 style (preferred, enabled via `merge.conflictStyle = diff3`):

```text
<<<<<<< HEAD
[head_code]
||||||| base
[base_code]
=======
[incoming_code]
>>>>>>> commit message
```

Standard style (no base section):

```text
<<<<<<< HEAD
[head_code]
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

### Step 3: Continue

After all conflicts are resolved and staged:

1. If lock files were resolved, regenerate them now:
   - `package-lock.json` -- `npm install`
   - `pnpm-lock.yaml` -- `pnpm install`
   - `yarn.lock` -- `yarn install`
   - `bun.lockb` or `bun.lock` -- `bun install`
   - `Cargo.lock` -- `cargo generate-lockfile`
   - `poetry.lock` -- `poetry lock --no-update`
   - `Gemfile.lock` -- `bundle install`
   - `composer.lock` -- `composer install`
   - Stage the regenerated lock file: `git add <lockfile>`
2. Run the appropriate continue command:

   | Context | Continue command |
   | --- | --- |
   | rebase | `git rebase --continue` |
   | merge | `git commit --no-edit` |
   | cherry-pick | `git cherry-pick --continue` |
   | revert | `git revert --continue` |

3. If more conflicts arise (rebase), loop back to Step 2
4. When complete, report a summary: conflicts resolved (auto-resolved vs user-resolved), lock files regenerated, and rerere resolutions if any were applied (rerere is enabled globally and records/replays resolutions automatically)
