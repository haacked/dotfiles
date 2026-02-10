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

Build the standup content with clickable links for Slack. You'll generate both:
1. **Plain text** (for the archive file)
2. **HTML** (for RTF clipboard copy - links work when pasted into Slack)

**Completed Section:**

- List all PRs that were merged since `last_standup_date`
- Use **past tense** for the description
- The entire description is the link text
- Use backticks for code/method names (these render in Slack)

Plain text format:
```
Added `getFeatureFlagResult` method for efficient flag + payload retrieval (https://github.com/PostHog/posthog-js/pull/2920)
```

HTML format (for clipboard):
```html
<a href="https://github.com/PostHog/posthog-js/pull/2920">Added <code>getFeatureFlagResult</code> method for efficient flag + payload retrieval</a>
```

**Working On Section:**

- Include open PRs with recent activity
- Include items from previous standup's "Working on" that aren't in Completed
- Description first, then status indicator in parentheses as a link
- Determine PR status:
  - If `isDraft` is true: link text is "draft"
  - If `reviewRequests` includes "feature-flags" team or any reviewer: link text is "needs review"
  - Otherwise for open PRs: link text is "PR"
- For non-PR work items: just plain text description

Plain text format:
```
Simplify readiness probe to prevent cascade failures (https://github.com/PostHog/posthog/pull/46589 - draft)
```

HTML format (for clipboard):
```html
Simplify readiness probe to prevent cascade failures (<a href="https://github.com/PostHog/posthog/pull/46589">draft</a>)
```

**Discussion Section:**

- Default to a playful "nothing" variant
- Rotate between: "Nothing", "Nada", "Ain't got a thing", "Zilch", "Not a thing", "All quiet on the western front"

### Step 5: Write the Standup Notes

Create the **plain text file** at `new_file_path` for archival:

```text
Completed:
Did something awesome (https://github.com/org/repo/pull/123)
Fixed the thing that was broken (https://github.com/org/repo/pull/456)

Working on:
Description of draft work (https://github.com/org/repo/pull/789 - draft)
Description of work needing review (https://github.com/org/repo/pull/101 - needs review)
Non-PR work item description

Discussion:
Nothing
```

### Step 6: Copy to Clipboard as Rich Text

Generate HTML and copy to clipboard as rich text. This makes links clickable when pasted into Slack.

Use `<ul><li>` for bullet lists — Slack renders these properly when pasting rich text.

Create the HTML content:

```html
<b>Completed:</b><br>
<ul>
<li><a href="https://github.com/org/repo/pull/123">Did something awesome</a></li>
<li><a href="https://github.com/org/repo/pull/456">Fixed the thing that was broken</a></li>
</ul>
<b>Working on:</b><br>
<ul>
<li>Description of draft work (<a href="https://github.com/org/repo/pull/789">draft</a>)</li>
<li>Description of work needing review (<a href="https://github.com/org/repo/pull/101">needs review</a>)</li>
<li>Non-PR work item description</li>
</ul>
<b>Discussion:</b><br>
<ul>
<li>Nothing</li>
</ul>
```

Copy to clipboard using the helper script:

```bash
echo '<html content>' | swift ~/.claude/skills/standup/scripts/copy-html-to-clipboard.swift
```

Or with a heredoc for multiline HTML:

```bash
swift ~/.claude/skills/standup/scripts/copy-html-to-clipboard.swift <<'EOF'
<b>Completed:</b><br>
<ul>
<li>...</li>
</ul>
EOF
```

### Step 7: Report to User

Display:

1. The generated standup notes (plain text version for review)
2. The file path for easy access
3. A message: "✅ Copied to clipboard as rich text — paste directly into Slack!"

## Example Output

**Plain text (saved to file):**
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

**HTML (copied to clipboard as rich text):**
```html
<b>Completed:</b><br>
<ul>
<li><a href="https://github.com/PostHog/posthog-js/pull/2920">Added <code>getFeatureFlagResult</code> method for efficient flag + payload retrieval</a></li>
<li><a href="https://github.com/PostHog/posthog-js/pull/2824">Added bin scripts for setup, build, and test</a></li>
</ul>
<b>Working on:</b><br>
<ul>
<li>Simplify readiness probe to prevent cascade failures (<a href="https://github.com/PostHog/posthog/pull/46589">draft</a>)</li>
<li>Add source field to feature flag created analytics (<a href="https://github.com/PostHog/posthog/pull/46782">needs review</a>)</li>
<li>Add HyperCache support to flag definitions cache (<a href="https://github.com/PostHog/posthog/pull/44701">needs review</a>)</li>
<li>Completing migration of celery tasks to dedicated flags queue</li>
</ul>
<b>Discussion:</b><br>
<ul>
<li>Zilch</li>
</ul>
```

## Notes

- The standup notes are stored in `~/dev/haacked/notes/PostHog/standup/`
- Files are named `YYYY-MM-DD.md` for easy sorting
- Previous standup notes are used to identify carry-over work items
- The Discussion section adds personality with varied "nothing" responses
- **Rich text clipboard**: Uses HTML with `<ul><li>` lists — links are clickable when pasted into Slack
- **Plain text file**: Archived for reference with URLs in parentheses
- Completed items use past tense with the whole description as link text
- Working on items have plain text description + status as link in parentheses
