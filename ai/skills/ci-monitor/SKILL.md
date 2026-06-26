---
name: ci-monitor
description: Monitor CI checks after pushing, detect flaky vs legit failures, and auto-fix
argument-hint: "[<pr-number>|<pr-url>|--no-fix|--timeout <min>|--auto-approve-base-sync]"
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
- `--auto-approve-base-sync` - For a re-gated fork PR, auto-approve the gated workflows **only** when the sole change since your last approval was a base-branch sync (merge/rebase of the base branch) with the contributor's patch unchanged. Off by default; without it, gated runs are always left for you to approve manually.

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
- `--auto-approve-base-sync` - Set `AUTO_APPROVE_BASE_SYNC=true` (default: `false`)

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

Initialize `ALERTED_APPROVAL_RUNS` to an empty set. It tracks the `run_id`s of awaiting-approval workflows you have already alerted about, so re-polling does not re-alert for the same runs (see Step 6).

### Step 2: Check CI Status

Run the status check:

```bash
~/.claude/skills/ci-monitor/scripts/ci-check-status.sh $PR_NUMBER "$ORG/$REPO" 2>&1
```

Save the output as `CHECK_DATA`.

**Route based on status:**

- If `awaiting_approval` is greater than 0: Go to **Step 6** (Awaiting Approval). Check this **first**, before every rule below. An outside-contributor (fork) PR can report `no_checks` or even `all_passed` in the rollup while its real CI sits gated behind your approval, so this must take precedence.
- If `status` is `"no_checks"`: Tell the user "No CI checks found for this PR.", apply the **fork caveat** below, and stop.
- If `all_passed` is `true`: Report "All CI checks passed!" with a summary of check counts, apply the **fork caveat** below, and stop.
- If `status` is `"in_progress"`: Go to **Step 3** (Polling Loop).
- If `status` is `"completed"` and there are failures: Go to **Step 4** (Triage Failures).
- If `status` is `"completed"`, there are **no** failures, and `all_passed` is `false` (for example, all remaining checks are skipped, cancelled, or neutral): Report that CI checks have completed with no failures, show a final summary including all buckets (passed, skipped, cancelled, neutral, etc.), apply the **fork caveat** below, and stop.

**Fork caveat:** When `is_cross_repository` is `true` and you stop from one of the three terminal branches above (`no_checks`, `all_passed`, or completed-with-no-failures), add: "This is a fork PR. If you expected gated workflows that still need maintainer approval, confirm on the PR's Checks tab; approval detection relies on a runs-API call that could have been missed."

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

**Checkout safety check:** The fix handler commits and pushes to your **current local branch**, so fixing is only safe when that branch is checked out at the PR's head commit. Run `git rev-parse HEAD` and compare it to `head_sha` from `CHECK_DATA` (use the per-poll value, not `PR_DATA`, which was captured in Step 1 and goes stale after a fix-and-push):

- If they **match**, proceed (for a fork PR, the push also requires "Allow edits from maintainers" on the PR).
- If they do **not** match, you are not on the PR's branch. Do **not** fix: a commit would land on the wrong branch. Report the legit failures and tell the user: "Your local checkout is not at this PR's head. To auto-fix, run `gh pr checkout $PR_NUMBER` first, then re-run `/ci-monitor $PR_NUMBER`; otherwise fix manually." If `is_cross_repository` is `true`, add: "(`gh pr checkout` on a fork PR needs 'Allow edits from maintainers' enabled.)" Then stop.

Load the fix handler:

```
Read ~/.claude/skills/ci-monitor/handlers/fix.md
```

Follow the instructions in the handler. After the handler completes (fix committed and pushed), increment `RETRY_COUNT` and go back to **Step 2** to monitor the new push.

### Step 6: Awaiting Approval (Outside-Contributor PRs)

`CHECK_DATA` reports `awaiting_approval > 0`. This PR is from a fork, and GitHub is holding its `pull_request` workflows until a maintainer clicks **Approve and run**. Approving lets the contributor's code execute on the repo's CI runners (with whatever secrets those workflows expose), so the goal here is to scan for danger, alert the user with that read, and let **them** approve. **Do not approve a run yourself**, with one exception: a verified base-branch sync when the user passed `--auto-approve-base-sync` (6b). In every other case the human approves.

The `awaiting_approval_checks` array holds one entry per gated workflow: `workflow`, `link` (the run URL), and `run_id`.

**6a. Decide whether this is a new alert.**

Compute `NEW_RUNS` = the entries in `awaiting_approval_checks` whose `run_id` is **not** in `ALERTED_APPROVAL_RUNS`.

- If `NEW_RUNS` is empty, you have already alerted for everything currently gated. Skip to **6e** (keep polling quietly).
- Otherwise continue to 6b.

**6b. Check whether this re-gating is only a base-branch sync.**

A fork PR re-gates on every push, including a maintainer/contributor clicking **Update branch** (a merge or rebase of the base branch). When the *only* change since your last approval was such a sync, with the contributor's own patch unchanged, re-approving is exactly as safe as the approval you already gave. Determine that:

```bash
~/.claude/skills/ci-monitor/scripts/ci-approval-safety.sh $PR_NUMBER "$ORG/$REPO" 2>&1
```

Save the output as `SAFETY`. It is read-only (it never approves anything) and fails closed: any error, uncertainty, a changed contributor patch, or a `pull_request_target` gated run yields `safe: false`.

- If `SAFETY.safe` is `true` **and** `AUTO_APPROVE_BASE_SYNC` is `true`: this is a verified base-branch sync. Approve **only** the runs the script verified, once per `run_id` in `SAFETY.gated_run_ids` (not the ids from `awaiting_approval_checks` — those came from an earlier poll and may point at a different head; `gated_run_ids` is the exact set validated at `SAFETY.current_head_sha`). If `SAFETY.gated_run_ids` is empty, approve nothing and fall through to 6c.

  ```bash
  gh api -X POST repos/$ORG/$REPO/actions/runs/<run_id>/approve
  ```

  Then emit a one-line audit alert naming the count, the last approved sha (`SAFETY.last_approved_sha`), and the current head sha (`SAFETY.current_head_sha`), and stating that it was a base-branch sync only with the contributor patch unchanged. Add every approved `run_id` to `ALERTED_APPROVAL_RUNS`, then go to **6e**. Skip 6c and 6d; no human action is needed, and the prior approval's safety scan still applies because the patch is unchanged.

- If `SAFETY.safe` is `true` but `AUTO_APPROVE_BASE_SYNC` is `false`: continue to 6c, but include in the alert that this appears to be a base-branch sync only (contributor patch unchanged since `$SAFETY.last_approved_sha`), so approval is low-risk. Still let the user approve.

- If `SAFETY.safe` is `false`: continue to 6c as normal (new or changed contributor code, or undeterminable; treat as a fresh approval decision).

**6c. Scan for approval safety.**

Delegate a read-only safety read to the `assess-fork-pr` agent and **wait for its verdict** (you need it before alerting):

```text
Agent tool with:
  subagent_type: assess-fork-pr
  prompt: |
    Assess whether it is safe to approve the gated CI workflows on this fork PR.
    PR: $PR_NUMBER
    Repo: $ORG/$REPO
```

Keep the returned verdict block (risk level, reasons, files to watch).

**6d. Alert the user.**

Present a single, prominent alert:

- "PR #$PR_NUMBER ($ORG/$REPO) is from a fork and has **N workflow(s) awaiting your approval** to run."
- List the gated workflow names (cap at ~10; if more, show the count and the first 10).
- Include the safety verdict block from 6c verbatim.
- **Primary action:** "Review and approve at <https://github.com/$ORG/$REPO/pull/$PR_NUMBER>. The **Approve and run** button on the Checks tab approves all gated workflows at once."
- **Power-path (optional):** approve runs individually via the API, one call per `run_id`: `gh api -X POST repos/$ORG/$REPO/actions/runs/<run_id>/approve`.
- Make clear you will **not** approve on their behalf, and that the safety scan only covers the PR diff (it cannot see how the base repo's existing workflows handle secrets).

Add every `run_id` in `NEW_RUNS` to `ALERTED_APPROVAL_RUNS`.

**6e. Keep polling.**

The user chose to be alerted and let monitoring continue, so wait for them to approve:

- **Check timeout:** Calculate elapsed time since `START_TIME`. If it exceeds `TIMEOUT_MINUTES * 60` seconds, tell the user "Still awaiting your approval of N workflow(s) after $TIMEOUT_MINUTES minutes. Approve at <https://github.com/$ORG/$REPO/pull/$PR_NUMBER>, then re-run `/ci-monitor $PR_NUMBER`." and stop.
- Otherwise report "Waiting for you to approve N workflow(s)… checking again in 30 seconds." then:

  ```bash
  sleep 30
  ```

  Go back to **Step 2**. Once you approve, the gated workflows start running: `awaiting_approval` drops and they appear as normal pending/failed checks, so monitoring resumes automatically. If a later push adds new gated workflows, 6a detects the new `run_id`s and alerts again.
