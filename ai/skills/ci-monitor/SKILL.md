---
name: ci-monitor
description: Monitor CI checks after pushing, detect flaky vs legit failures, and auto-fix
argument-hint: "[<pr-number>|<pr-url>|--no-fix|--timeout <min>]"
allowed-tools: Bash(~/.claude/skills/ci-monitor/scripts/*:*, ~/.dotfiles/bin/detect-pr.sh:*, sleep:*, gh:*, git:*), Read(~/.claude/skills/ci-monitor/**), Write, Edit, Agent
model: sonnet
---

Monitor GitHub CI checks for the current PR, wait for completion, classify failures as flaky or legit, and guide fixes for legit failures.

**Arguments:**

- `(no argument)` - Detect PR from current branch
- `<pr-number>` - Monitor checks for a specific PR (e.g., `123`)
- `<pr-url>` - Monitor checks for PR by URL (e.g., `https://github.com/org/repo/pull/123`)

**Optional Flags:**

- `--no-fix` - Monitor and report only; do not attempt fixes
- `--timeout <minutes>` - Override default 30-minute timeout

**Usage examples:**

- `/ci-monitor` - Monitor CI for current branch's PR
- `/ci-monitor 123` - Monitor CI for PR #123
- `/ci-monitor --no-fix` - Monitor only, report failures without fixing
- `/ci-monitor https://github.com/org/repo/pull/123 --timeout 45`

---

## Implementation

**CRITICAL:** Follow these steps in order. If any step fails, inform the user and stop.

### Step 1: Parse Arguments

Extract the PR identifier and flags from `$ARGUMENTS`.

**Flags to detect:**
- `--no-fix` - Set `NO_FIX=true`
- `--timeout <N>` - Set `TIMEOUT_MINUTES=N` (default: 30)

Remove flags from the argument string, leaving just the PR identifier (number, URL, or empty).

Run the detection script:

```bash
~/.dotfiles/bin/detect-pr.sh --json ${PR_IDENTIFIER:+"$PR_IDENTIFIER"} 2>&1
```

Save the output as `PR_DATA`. If the `error` field is non-null, display the error and stop.

Extract and save: `PR_NUMBER`, `ORG`, `REPO`, `HEAD_BRANCH`.

Tell the user: "Monitoring CI checks for PR #$PR_NUMBER ($ORG/$REPO)…"

Record the current time as `START_TIME` for timeout tracking.

Initialize `RETRY_COUNT=0` and `MAX_RETRIES=3`.

### Step 2: Check CI Status

Run the status check:

```bash
~/.claude/skills/ci-monitor/scripts/ci-check-status.sh $PR_NUMBER "$ORG/$REPO" 2>&1
```

Save the output as `CHECK_DATA`.

**Route based on status:**

- If `status` is `"no_checks"`: Tell the user "No CI checks found for this PR." and stop.
- If `all_passed` is `true`: Report "All CI checks passed!" with a summary of check counts and stop.
- If `status` is `"in_progress"`: Go to **Step 3** (Polling Loop).
- If `status` is `"completed"` and there are failures: Go to **Step 4** (Triage Failures).
- If `status` is `"completed"`, there are **no** failures, and `all_passed` is `false` (for example, all remaining checks are skipped, cancelled, or neutral): Report that CI checks have completed with no failures, show a final summary including all buckets (passed, skipped, cancelled, neutral, etc.), and stop.

### Step 3: Polling Loop

Checks are still running. Report progress:

"CI checks in progress: $PASSED/$TOTAL passed, $PENDING pending. Checking again in 30 seconds…"

Retain only the summary scalars from `CHECK_DATA` (status, total, passed, failed, pending). Discard the full JSON until status is `"completed"`.

Wait 30 seconds:

```bash
sleep 30
```

**Check timeout:** Calculate elapsed time. If elapsed exceeds `TIMEOUT_MINUTES * 60` seconds, tell the user "Timeout reached after $TIMEOUT_MINUTES minutes. $PENDING checks still pending." and show the current check status. Stop.

Go back to **Step 2** to re-check status.

### Step 4: Triage Failures

For each failed check in the `failed_checks` array:

**4a. Fetch failure logs:**

If the check has a `run_id`:

```bash
~/.claude/skills/ci-monitor/scripts/ci-fetch-logs.sh $RUN_ID "$ORG/$REPO" 2>&1
```

Save as `LOG_DATA`.

If the check does **not** have a `run_id` (e.g., a non-GitHub Actions status check):
- Mark it as `uncertain` — no logs are available to classify it
- Report the check name and link to the user
- Do not attempt to classify, re-run via `gh run rerun`, or auto-fix this check
- Skip steps 4b and 4c for this check; move on to the next failed check

**4b. Classify failure:**

Pass the log excerpt via stdin to the classifier:

```bash
printf '%s\n' "$LOG_EXCERPT" | ~/.claude/skills/ci-monitor/scripts/ci-classify-failure.sh $PR_NUMBER "$WORKFLOW_NAME" "$ORG/$REPO" 2>&1
```

Where `$LOG_EXCERPT` is the combined `log_excerpt` from all failed jobs in `LOG_DATA`, and `$WORKFLOW_NAME` is the check's `workflow` field.

Save as `CLASSIFICATION`.

**4c. Present findings to the user:**

For each failure, report:
- Check name and link
- Classification: flaky / legit / uncertain
- Confidence score
- Reasoning (why classified this way)
- Key log excerpt (first 20-30 relevant lines)

**4d. Handle by classification:**

**All flaky:** Report as flaky. Ask the user one combined question: "All failures appear to be flaky. Re-run failed workflows, and report the flake(s) to Mendral?"

If they approve the re-run, for each failed check with a `run_id`:

```bash
gh run rerun $RUN_ID --failed --repo "$ORG/$REPO"
```

If they also approve reporting to Mendral, delegate each distinct flaky failure to the `report-flake` agent so it dedups against known incidents and reports genuine unknown flakes while monitoring continues. Spawn it fire-and-forget (the user already consented, so it runs in `post` mode) and do not wait on it:

```text
Agent tool with:
  subagent_type: report-flake
  run_in_background: true
  prompt: |
    Report this flaky CI failure.
    Job URL: <check_link>
    Test/signature if known: <test name + error line from CLASSIFICATION>
    Repo: $ORG/$REPO
    mode: post
```

The agent dedups before posting, so a flake already tracked by Mendral won't produce a duplicate post. If the user declines reporting, skip the delegation.

Then go back to **Step 2** to monitor the re-run (this does NOT count against `RETRY_COUNT`).

**All legit or mixed (with `--no-fix`):** Report the findings and stop. Do not attempt fixes.

**All legit or mixed (without `--no-fix`):** Build `LEGIT_FAILURES` (see below), then go to **Step 5**.

**Uncertain classifications:** Present your own analysis of the log excerpt alongside the automated classification. Use your judgment to refine the classification before proceeding. Treat uncertain failures you judge to be legit the same as legit failures when building `LEGIT_FAILURES`.

**Building `LEGIT_FAILURES`:** Before entering Step 5, construct an array containing one entry per legit or uncertain failure. Each entry carries only compact identifiers:
- `check_name` — the check's name
- `check_link` — the check's URL
- `run_id` — the run ID (may be null for non-Actions checks)
- `workflow` — the workflow name
- `classification` — the full `CLASSIFICATION` object from step 4b (scores and reasoning, no log text)

Do not embed `log_data` in this array. The fix handler re-fetches the log excerpt for each failure it is actively fixing. This array is what the fix handler refers to as `failed_checks`.

### Step 5: Fix Cycle

Check `RETRY_COUNT`: if `>= MAX_RETRIES`, tell the user "Max fix retries (${MAX_RETRIES}) reached. Please investigate manually." and stop.

Load the fix handler:

```
Read ~/.claude/skills/ci-monitor/handlers/fix.md
```

Follow the instructions in the handler. After the handler completes (fix committed and pushed), increment `RETRY_COUNT` and go back to **Step 2** to monitor the new push.
