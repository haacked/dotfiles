---
name: review-fix-cycle
description: Run one review-fix iteration — review code, fix findings, simplify, and commit.
argument-hint: "[<review-target>] [--iteration N]"
---

# Review-Fix Cycle

Run one full review-fix-simplify-commit cycle. Designed to be invoked repeatedly (with fresh context each time) by the `review-fix-loop.sh` wrapper script, but can also be run standalone.

**Arguments:**

- `<review-target>` — Anything `/review-code` accepts: PR URL, PR number, branch name, commit, range. If omitted, auto-detects (see Step 1).
- `--iteration N` — Iteration number (default 1). Used for logging and status tracking.

---

## Implementation

### Step 1: Parse Arguments

Extract from `$ARGUMENTS`:
- `--iteration N` (default to `1`)
- Everything else is the review target

Determine the review target:

1. If an explicit target was provided, use it as-is.
2. If no target, auto-detect:

```bash
gh pr list --head "$(git branch --show-current)" --json number --jq '.[0].number' 2>/dev/null
```

- If a PR number is returned, use that as the target.
- Otherwise, use the current branch name: `git branch --show-current`

Save the resolved target as `$REVIEW_TARGET`.

Set up the notes directory:

```bash
mkdir -p "$(git rev-parse --show-toplevel)/.notes"
```

### Step 2: Run Review

Invoke the review-code skill:

```
Skill("review-code", args: "--force --append $REVIEW_TARGET")
```

Using `--append` ensures each iteration builds upon the previous review. The review agents receive the existing review as context and focus only on NEW findings — they skip already-raised issues, update status for resolved ones, and avoid duplicating work.

Wait for the review to complete before proceeding.

### Step 3: Locate and Read the Review File

Get the review file path:

```bash
~/.claude/skills/review-code/scripts/review-file-path.sh
```

Parse the JSON output and extract the `file_path` field. Then use the Read tool to read the review file contents.

### Step 4: Triage Findings

Parse the review markdown for findings from the **latest review section only**. When `--append` is used, the file may contain prior review sections separated by `---`. Focus on findings after the last separator (or the entire file on the first iteration).

Findings are prefixed with code-formatted severity markers:

- `` `blocking` `` — Must fix. Bugs, security issues, breakage.
- `` `suggestion` `` — Worth considering. Author's call.
- `` `nit` `` — Minor style/naming. Take it or leave it.
- `` `question` `` — Clarification needed. Not necessarily a problem.

**Categorize each finding:**

**Fix** (always):
- All `blocking` findings
- `suggestion` findings that fix correctness, security, or clarity issues
- `suggestion` findings with concrete code improvements that make the code simpler or cleaner
- `nit` findings that are clearly correct and easy to apply

**Skip** (only when):
- The suggestion is factually wrong or based on a misunderstanding of the code
- The suggestion is genuinely ambiguous and could go either way
- The suggestion would make the code worse (more complex, less readable)
- `question` findings (these are informational, not actionable)

Count the findings: `$TOTAL_FINDINGS`, `$TO_FIX`, `$TO_SKIP`.

**If zero actionable findings:** Jump to Step 8 and write the status file with `"clean": true, "fixed": 0, "skipped": 0, "committed": false`. Skip Steps 5, 6, and 7.

### Step 5: Apply Fixes

Process findings in priority order: blocking first, then suggestions, then nits.

For each actionable finding:
1. Read the referenced file at the indicated line
2. Apply the fix:
   - Use the concrete code fix from the review if one is provided (blocking and suggestion findings always include one)
   - For nits, use the description to determine the appropriate change
3. Verify the fix makes sense in context before writing it

For each skipped finding, append to `.notes/review-skipped.md`:

```markdown
## Iteration $N — $DATE

### Skipped: $FINDING_TITLE
**Reason:** $WHY_SKIPPED
**Source:** $AGENT_NAME, `$FILE:$LINE`
```

Use append mode (do not overwrite previous iterations).

### Step 6: Simplify

Invoke the simplify skill to review the changes just made:

```
Skill("simplify")
```

Apply any improvements it suggests.

### Step 7: Commit

Invoke the commit skill with force mode:

```
Skill("commit", args: "--force Address review feedback (iteration $N)")
```

### Step 8: Write Status File

Write the status file to `.notes/review-cycle-status.json`:

```bash
REPO_ROOT=$(git rev-parse --show-toplevel)
```

Use the Write tool to create `$REPO_ROOT/.notes/review-cycle-status.json`:

```json
{
  "iteration": $N,
  "clean": $CLEAN,
  "total_findings": $TOTAL_FINDINGS,
  "fixed": $TO_FIX,
  "skipped": $TO_SKIP,
  "committed": $COMMITTED,
  "timestamp": "$ISO_TIMESTAMP"
}
```

Where:
- `clean` is `true` if zero actionable findings were found
- `committed` is `true` if a commit was made (false if clean or all skipped)

Report the iteration summary to the user:

```
Review-fix cycle iteration $N complete.
Findings: $TOTAL_FINDINGS total, $TO_FIX fixed, $TO_SKIP skipped.
Status: $STATUS
```
