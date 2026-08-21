# Fix Handler

Fix legit CI failures based on error logs, commit, and push.

## Prerequisites

Before this handler runs, the following variables should be available from SKILL.md:
- `PR_NUMBER` - The PR number
- `ORG` - The GitHub organization or user
- `REPO` - The repository name
- `RETRY_COUNT` - Current fix attempt number
- `EVICTION_FIX` - True when this fix repairs a failure that got the PR dropped from the merge queue (SKILL.md Step 7b). The `failed_checks` entries then carry `run_id`s from the **merge PR's** runs: fetching their logs is fine, re-running them is not — those runs belong to Trunk.
- `failed_checks` - Array of legit/uncertain failures with compact identifiers (check_name, check_link, run_id, workflow, classification); log data is not pre-loaded

## Instructions

### 1. Present Diagnosis

For each legit or uncertain failure, fetch its logs first (if `run_id` is non-null):

```bash
~/.dotfiles/ai/skills/ci-monitor/scripts/ci-fetch-logs.sh "$run_id" "$ORG/$REPO" 2>&1
```

Then show:
- Check name and URL
- Classification and confidence
- The most relevant portion of the log excerpt (focus on the actual error, not setup/teardown output)
- Your analysis of what went wrong

### 2. Ask for Approval

Use AskUserQuestion:
- Question: "Found N legit CI failure(s). Attempt to fix?"
- Options:
  1. "Fix all" - Attempt to fix all legit failures
  2. "Skip" - Report only, do not fix
  3. When `EVICTION_FIX` is true: "Re-enqueue as-is instead" - treat the failures as flaky after all. Otherwise: "Re-run instead" - re-run the failed workflows (treat as potentially flaky)

If user selects "Skip", stop and return to SKILL.md (do not fix).

If user selects "Re-enqueue as-is instead", set `EVICTION_FIX=false` and return to SKILL.md **Step 7c** without fixing — a `gh run rerun` on Trunk's runs does nothing for the queue, so re-entry is the only useful retry. The PR is unchanged on this path, so the eviction comment still describes its head and 7c's gate needs no freshness waiver.

If user selects "Re-run instead", iterate over `failed_checks` and re-run each entry that has a non-null `run_id`:
```bash
# For each failure in failed_checks where run_id is not null, using that entry's run_id:
gh run rerun "$run_id" --failed --repo "$ORG/$REPO"
```
Return to SKILL.md to re-monitor.

### 3. Diagnose and Fix

For each failure the user approved:

**3a. Understand the error:**
- Use the log excerpt fetched in step 1 (re-fetch if not yet retrieved for this failure)
- Identify the specific error message, failing test, or build error
- Determine which file(s) are involved

**3b. Read the relevant code:**
- Read the files referenced in the error
- Understand the context around the failing code

**3c. Apply the fix:**
- Make targeted, minimal changes to fix the specific error
- Do not refactor or improve unrelated code
- If the fix requires changes you are not confident about, tell the user what you think the issue is and ask for guidance instead of guessing

**3d. Verify locally if possible:**
- If you can identify the test command from the error log (e.g., `pytest`, `npm test`, `cargo test`), run the specific failing test locally
- If local verification passes, proceed
- If local verification fails, investigate further before committing
- If you cannot determine how to run the test locally, skip local verification

### 4. Commit and Push

Stage only the files you changed:
```bash
git add <changed-files>
```

Commit with a descriptive message:
```bash
git commit -m "Fix CI: <brief description of fix>"
```

Push to the branch:
```bash
git push
```

### 5. Return

After pushing, return control to SKILL.md. The main flow will increment `RETRY_COUNT` and go back to polling.

## Safety Rules

- **Never force-push.** If `git push` fails, inform the user.
- **Never push a branch a merge queue is holding.** A push drops the PR out silently: the queue discards the run in flight and the PR loses its place, with nothing on the PR saying so. SKILL.md runs this gate before loading this handler; if you learn mid-fix that the PR entered the queue, stop before pushing — re-run `ci-queue-status.sh` and push only on a state Step 5's allowlist admits. Anything else, including an unreadable answer, means the queue is holding it, and not knowing counts as holding. Tell the user to cancel with `/trunk cancel` first; never comment `/trunk cancel` yourself, and never comment `/trunk merge` outside SKILL.md Step 7c's gate.
- **Never commit unrelated files.** Only stage files you explicitly changed.
- **Never guess at fixes you are not confident about.** Ask the user instead.
- **Never modify CI configuration files** (workflow YAML, Dockerfiles, etc.) without explicit user approval.
