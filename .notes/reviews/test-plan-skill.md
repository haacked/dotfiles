# Review: ai/skills/test-plan/SKILL.md

Reviewed for efficiency issues in the skill's instruction flow.

## Important

### 1. `git log` and `git diff` should run in parallel (not sequentially after the first batch)

**Location:** Lines 42-53, Step 2 "Gather Context"

**Problem:** The skill defines two rounds of commands -- first `git rev-parse` and `gh repo view` in parallel, then `git log` and `git diff` sequentially. But `git log` and `git diff` only depend on the base branch name (from `gh repo view`), not on the current branch name (from `git rev-parse`). Meanwhile, `git rev-parse --abbrev-ref HEAD` is never referenced again anywhere in the skill. Its output is gathered but unused.

The second batch (`git log` + `git diff`) is presented as a sequential list without an explicit "run in parallel" instruction, unlike the first batch. Compare to the `create-pr` skill (line 45-50) which explicitly says "run in parallel" for its equivalent `git log`, `git diff`, and `gh pr view` calls.

**Impact:** Two wasted round-trips. The LLM will (a) wait for batch 1 to finish before starting batch 2, and (b) run `git log` and `git diff` sequentially within batch 2. On repos with large diffs, the `git diff` alone can take seconds.

**Solution:** Collapse into a single parallel batch (after resolving the base branch). Also, `git rev-parse --abbrev-ref HEAD` can be dropped entirely since the skill never uses the current branch name. If it is kept for display purposes, move it into the parallel batch:

```markdown
Run in parallel:

\```bash
git rev-parse --abbrev-ref HEAD
gh repo view --json defaultBranchRef -q .defaultBranchRef.name
\```

Then, using the base branch name, run in parallel:

\```bash
git log <base>..HEAD --oneline
git diff <base>..HEAD
\```
```

The key change is adding "run in parallel" to the second batch. The `create-pr` skill already uses this pattern correctly.

**Confidence:** 90

### 2. `git rev-parse --abbrev-ref HEAD` result is gathered but never used

**Location:** Line 44

**Problem:** The current branch name is fetched but never referenced in any subsequent step. The skill never displays it, uses it in a command, or includes it in the output. This is a redundant git command.

**Impact:** Minor -- one unnecessary subprocess invocation per skill run. More importantly, it adds cognitive noise to the instructions and may confuse the LLM about whether it needs to incorporate the branch name somewhere.

**Solution:** Remove `git rev-parse --abbrev-ref HEAD` unless a future step needs it. If you want to display the branch name in the test plan header or the preview, add that reference explicitly.

**Confidence:** 95

### 3. No short-circuit before running `git diff` on large diffs

**Location:** Lines 50-55

**Problem:** The skill runs `git diff <base>..HEAD` unconditionally, then checks if there are no commits to short-circuit. The `git log` output alone is sufficient to detect "no changes" -- if there are zero commits ahead of base, the diff will also be empty. But by running both in the same step, the LLM has already waited for the full diff output before evaluating the early-exit condition.

**Impact:** On branches with no changes, this is a minor waste. On branches with changes, this ordering is fine. The real cost is conceptual: the short-circuit check references "no commits ahead of base" (a `git log` concern) but the diff has already been fetched. If the goal is efficiency, check `git log` first, exit if empty, then fetch the diff.

**Solution:** Restructure to check `git log` before requesting the diff:

```markdown
Using the base branch name:

\```bash
git log <base>..HEAD --oneline
\```

If there are no commits ahead of base, tell the user there are no changes and stop.

Otherwise:

\```bash
git diff <base>..HEAD
\```
```

This saves the full diff fetch in the no-changes case. However, this trades parallelism for short-circuiting. For the common case (branch has changes), the current approach of fetching both in parallel would be faster. A pragmatic middle ground: run both in parallel and add the short-circuit as-is, accepting the wasted diff in the rare no-changes case. In that case, just add "run in parallel" to the second batch per issue #1.

**Confidence:** 80

## Summary

The main actionable finding is that the second batch of git commands (`git log` + `git diff`) lacks an explicit "run in parallel" instruction, unlike the equivalent pattern in the `create-pr` skill. Adding those two words will save a round-trip on every invocation. The unused `git rev-parse` is a minor cleanup. The short-circuit ordering is a design tradeoff that may not be worth changing depending on how often the skill is invoked on branches with no changes.
