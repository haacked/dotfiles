---
name: standup
description: Generate standup notes from GitHub PR activity
disable-model-invocation: true
---

# Standup Notes Generator

Generate standup notes for PostHog standups (Monday, Wednesday, Friday).

## Purpose

Every standup, you need to report:

- **Completed**: PRs merged since last standup
- **Working on**: PRs with recent activity + items from last standup not yet done
- **Discussion**: Usually something playful ("Nothing", "Nada", "Ain't got a thing")

## Your Task

### Step 1: Get Date Context

Run the helper script to get standup dates:

```bash
~/.claude/skills/standup/scripts/standup-dates.sh
```

This returns tab-separated: `<today>\t<last_standup_date>\t<new_file_path>`

Store these values:

- `today` - Today's date (for the new standup file)
- `last_standup_date` - When the previous standup was (for PR queries)
- `new_file_path` - Where to write the new standup notes

### Step 2: Find Previous Standup Notes

Run the helper script to find previous standup notes:

```bash
~/.claude/skills/standup/scripts/standup-find.sh
```

This returns tab-separated: `<status>\t<path>\t<date>`

If `status` is "found":

- Read the previous standup notes at `<path>`
- Extract the "Working on" items that are NOT completed (for carry-over)

### Step 3: Query GitHub for PR Activity

**Completed PRs** (merged since last standup):

```bash
gh search prs --author haacked --merged ">=${last_standup_date}" --json number,title,url,repository --limit 50
```

**Active PRs** (open PRs with recent activity) - include draft status and review requests:

```bash
gh pr list --author "@me" --state open --json number,title,url,isDraft,reviewRequests --repo PostHog/posthog
```

Also check for open PRs in other repos the user commonly works on:

- `PostHog/posthog-js`
- `PostHog/charts`
- `PostHog/posthog-cloud-infra`

**Recently Updated PRs** (may have changes since last standup even if not open):

```bash
gh search prs --author haacked --updated ">=${last_standup_date}" --state open --json number,title,url,repository --limit 30
```

### Step 4: Analyze and Compose Standup Notes

**IMPORTANT**: Output must be Slack-compatible. Use:

- NO bullet characters — just plain lines (user will convert to list after pasting)
- Slack mrkdwn link format: `<URL|display text>` — this renders as a clickable link in Slack
- Backticks for code/method names (Slack supports inline code)

**Completed Section:**

- List all PRs that were merged since `last_standup_date`
- Use **past tense** for the description
- The **entire description is the link**: `<URL|Past tense description>`
- Use backticks for method/class names within the link text

Example:
```
<https://github.com/PostHog/posthog-js/pull/2920|Added `getFeatureFlagResult` method for efficient flag + payload retrieval>
<https://github.com/PostHog/charts/pull/8170|Adjusted Feature Flags HPA alert durations for graduated escalation>
```

**Working On Section:**

- Include open PRs with recent activity
- Include items from previous standup's "Working on" that aren't in Completed
- Format: **Plain text description**, then **status link in parentheses**
- Determine PR status and link accordingly:
  - If `isDraft` is true: `Description (<URL|draft PR>)`
  - If `reviewRequests` includes "feature-flags" team or any reviewer: `Description (<URL|Needs review>)`
  - Otherwise for open PRs: `Description (<URL|PR>)`
- For non-PR work items: just plain text description

Example:
```
Simplify readiness probe to prevent cascade failures (<https://github.com/PostHog/posthog/pull/46589|draft PR>)
Add source field to feature flag created analytics (<https://github.com/PostHog/posthog/pull/46782|Needs review>)
Completing migration of celery tasks to dedicated flags queue
```

**Discussion Section:**

- Default to a playful "nothing" variant
- Rotate between: "Nothing", "Nada", "Ain't got a thing", "Zilch", "Not a thing", "All quiet on the western front"

### Step 5: Write the Standup Notes

Create the file at `new_file_path` with this Slack-compatible format:

```text
Completed:
<https://github.com/org/repo/pull/123|Did something awesome>
<https://github.com/org/repo/pull/456|Fixed the thing that was broken>

Working on:
Description of draft work (<https://github.com/org/repo/pull/789|draft PR>)
Description of work needing review (<https://github.com/org/repo/pull/101|Needs review>)
Non-PR work item description

Discussion:
Nothing
```

### Step 6: Report to User

Display:

1. The generated standup notes (so they can review and copy-paste to Slack)
2. The file path for easy access
3. A message: "Edit as needed, then paste into Slack!"

## Example Output

```text
Completed:
<https://github.com/PostHog/posthog-js/pull/2920|Added `getFeatureFlagResult` method for efficient flag + payload retrieval>
<https://github.com/PostHog/posthog-js/pull/2824|Added bin scripts for setup, build, and test>

Working on:
Simplify readiness probe to prevent cascade failures (<https://github.com/PostHog/posthog/pull/46589|draft PR>)
Add source field to feature flag created analytics (<https://github.com/PostHog/posthog/pull/46782|Needs review>)
Add HyperCache support to flag definitions cache (<https://github.com/PostHog/posthog/pull/44701|Needs review>)
Completing migration of celery tasks to dedicated flags queue

Discussion:
Zilch
```

## Notes

- The standup notes are stored in `~/dev/haacked/notes/PostHog/standup/`
- Files are named `YYYY-MM-DD.md` for easy sorting (though content is Slack-compatible, not markdown)
- Previous standup notes are used to identify carry-over work items
- The Discussion section adds personality with varied "nothing" responses
- No bullet characters — user converts to list in Slack after pasting
- Completed items use past tense with the whole description as a link
- Working on items use plain text + status link in parentheses
