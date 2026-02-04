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

**Active PRs** (open PRs with recent activity):

```bash
gh pr list --author "@me" --state open --json number,title,url,updatedAt --repo PostHog/posthog
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

**IMPORTANT**: Output must be Slack-compatible (not markdown). Use:

- `•` (bullet point character) for list items, NOT `*` or `-`
- Slack mrkdwn link format: `<URL|display text>` — this renders as a clickable link in Slack
- Backticks for code/method names (Slack supports inline code)

**Link Format:**

For PR links, use the format `<URL|repo#number>` which renders as a compact clickable link:
- `<https://github.com/PostHog/posthog/pull/123|posthog#123>`
- `<https://github.com/PostHog/posthog-js/pull/456|posthog-js#456>`
- `<https://github.com/PostHog/charts/pull/789|charts#789>`

**Completed Section:**

- List all PRs that were merged since `last_standup_date`
- Format: `• Brief description <URL|repo#number>`
- Use backticks for method/class names, e.g., `• Add \`getFeatureFlagResult\` method <URL|posthog-js#2920>`
- Group by theme if there are many

**Working On Section:**

- Include open PRs with recent activity
- Include items from previous standup's "Working on" that aren't in Completed
- Format: `• Brief description <URL|repo#number>` for PRs
- Format: `• Description` for non-PR work items

**Discussion Section:**

- Default to a playful "nothing" variant
- Rotate between: "Nothing", "Nada", "Ain't got a thing", "Zilch", "Not a thing", "All quiet on the western front"

### Step 5: Write the Standup Notes

Create the file at `new_file_path` with this Slack-compatible format:

```text
Completed:
• Description of work <https://github.com/org/repo/pull/123|repo#123>
• Another item

Working on:
• Current work item <https://github.com/org/repo/pull/456|repo#456>
• Continuing migration work

Discussion:
• Nothing
```

### Step 6: Report to User

Display:

1. The generated standup notes (so they can review and copy-paste to Slack)
2. The file path for easy access
3. A message: "Edit as needed, then paste into Slack!"

## Example Output

```text
Completed:
• Add `getFeatureFlagResult` method for efficient flag + payload retrieval <https://github.com/PostHog/posthog-js/pull/2920|posthog-js#2920>
• Add bin scripts for setup, build, and test <https://github.com/PostHog/posthog-js/pull/2824|posthog-js#2824>

Working on:
• Add HyperCache support to flag definitions cache <https://github.com/PostHog/posthog/pull/44701|posthog#44701>
• Completing migration of celery tasks to dedicated flags queue
• Looking into our K8s probes

Discussion:
• Zilch
```

## Notes

- The standup notes are stored in `~/dev/haacked/notes/PostHog/standup/`
- Files are named `YYYY-MM-DD.md` for easy sorting (though content is Slack-compatible, not markdown)
- Previous standup notes are used to identify carry-over work items
- The Discussion section adds personality with varied "nothing" responses
- Output uses `•` bullets and Slack mrkdwn links `<URL|text>` for rich formatting when pasted
