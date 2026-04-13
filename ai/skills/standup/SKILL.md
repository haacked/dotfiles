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
gh api search/issues --method GET -f q="author:haacked is:pr is:merged merged:>=${last_standup_date}" --jq '.items[] | {number, title, url: .html_url, repo: .repository_url, merged_at: .pull_request.merged_at}'
```

Note: `gh search prs --merged` is unreliable for date filtering — it returns stale results. Always use `gh api search/issues` with the `merged:` qualifier instead, which returns accurate `merged_at` timestamps.

**Active PRs** (open PRs with recent activity) — include draft status and review requests:

```bash
gh pr list --author "@me" --state open --json number,title,url,isDraft,reviewRequests --repo PostHog/posthog
```

Also check for open PRs in other repos the user commonly works on:

- `PostHog/posthog-js`
- `PostHog/posthog-dotnet`
- `PostHog/charts`
- `PostHog/posthog-cloud-infra`

**Recently Updated PRs** (may have changes since last standup even if not open):

```bash
gh api search/issues --method GET -f q="author:haacked is:pr is:open updated:>=${last_standup_date}" --jq '.items[] | {number, title, url: .html_url, repo: .repository_url}'
```

### Step 4: Compose and Save Standup Notes

Build standup content and produce two outputs: a plain text archive file and HTML for the clipboard.

#### Content Rules

**Completed items:**

- List all PRs merged since `last_standup_date`
- Use past tense; the entire description is the link text
- Use backticks (plain text) or `<code>` (HTML) for method/code names

**Working on items:**

- Include open PRs with recent activity
- Carry over items from the previous standup's "Working on" — but verify each one first:
  - For items with a PR URL: `gh pr view <number> --repo <owner/repo> --json state,mergedAt`
  - If **MERGED** since last standup: move to Completed (deduplicate by PR number — carry-over is the safety net for PRs the merged search may miss)
  - If **CLOSED**: drop it entirely
  - If **OPEN**: keep in Working on
- Determine PR status from the `gh pr list` JSON:
  - `isDraft: true` → link text is "draft"
  - `reviewRequests` includes any reviewer → link text is "needs review"
  - Otherwise → link text is "PR"
- For non-PR work items: plain text description only

**Discussion:**

- Default to a playful "nothing" variant
- Rotate between: "Nothing", "Nada", "Ain't got a thing", "Zilch", "Not a thing", "All quiet on the western front"

#### Plain Text File

Write to `new_file_path` for archival. Every item is a plain line. URLs appear in parentheses after the description.

```text
Completed:
Added `getFeatureFlagResult` method for efficient flag + payload retrieval (https://github.com/PostHog/posthog-js/pull/2920)
Added bin scripts for setup, build, and test (https://github.com/PostHog/posthog-js/pull/2824)

Working on:
Simplify readiness probe to prevent cascade failures (https://github.com/PostHog/posthog/pull/46589 - draft)
Add source field to feature flag created analytics (https://github.com/PostHog/posthog/pull/46782 - needs review)
Add HyperCache support to flag definitions cache (https://github.com/PostHog/posthog/pull/44701 - needs review)
Completing migration of celery tasks to dedicated flags queue

Discussion:
Zilch
```

#### HTML for Clipboard

Every section uses `<p><b>Header:</b></p>` followed by `<ul>`. Every item — without exception — is an `<li>` inside the `<ul>`, regardless of whether it contains a link.

```html
<p><b>Completed:</b></p>
<ul>
<li><a href="https://github.com/PostHog/posthog-js/pull/2920">Added <code>getFeatureFlagResult</code> method for efficient flag + payload retrieval</a></li>
<li><a href="https://github.com/PostHog/posthog-js/pull/2824">Added bin scripts for setup, build, and test</a></li>
</ul>
<p><b>Working on:</b></p>
<ul>
<li>Simplify readiness probe to prevent cascade failures (<a href="https://github.com/PostHog/posthog/pull/46589">draft</a>)</li>
<li>Add source field to feature flag created analytics (<a href="https://github.com/PostHog/posthog/pull/46782">needs review</a>)</li>
<li>Add HyperCache support to flag definitions cache (<a href="https://github.com/PostHog/posthog/pull/44701">needs review</a>)</li>
<li>Completing migration of celery tasks to dedicated flags queue</li>
</ul>
<p><b>Discussion:</b></p>
<ul>
<li>Zilch</li>
</ul>
```

Copy to clipboard using the shared helper script:

```bash
swift ~/bin/copy-html-to-clipboard.swift <<'EOF'
<p><b>Completed:</b></p>
<ul>
<li>...</li>
</ul>
EOF
```

### Step 5: Report to User

Display:

1. The generated standup notes (plain text version for review)
2. The file path for easy access
3. A message: "✅ Copied to clipboard as rich text — paste directly into Slack!"
