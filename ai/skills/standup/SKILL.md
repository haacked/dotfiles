---
name: standup
description: Generate standup notes from GitHub PR activity
disable-model-invocation: true
model: haiku
---

# Standup Notes Generator

Generate standup notes for PostHog standups (Monday, Wednesday, Friday).

## Purpose

Every standup, you need to report:

- **Completed**: core product (feature-flags domain) PRs merged since last standup
- **Working on**: PRs with recent activity + items from last standup not yet done
- **Side quests**: work outside the team's core product domain (internal dev tooling, infra side-projects, or cross-team contributions), each labeled with its state (In progress / Completed). Omit the section entirely when there are none.
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

This returns tab-separated: `<status>\t<path>\t<date>\t<posted_at>`

If `status` is "found":

- Read the previous standup notes at `<path>`
- Extract the "Working on" items that are NOT completed (for carry-over)
- Use `<posted_at>` (the file's modified time in UTC ISO 8601, e.g. `2026-06-17T16:00:00Z`) as the **merge cutoff** for Step 3, not the mechanical `last_standup_date` from Step 1. This is the moment you last posted, so PRs merged after it are picked up next time even when they landed the same day (post at 9am, merge at 10am → the 10am PR shows up in the next standup), while PRs merged before it aren't double-counted. It also covers skipped days: if you didn't work Friday, Monday's standup reaches back to Wednesday's standup, not to Friday.
- Set `cutoff` to `<posted_at>` for use in Step 3.

If `status` is "new", set `cutoff` to `last_standup_date` (date only).

### Step 3: Query GitHub for PR Activity

**Only include PRs from `PostHog/*` repos.** Personal repos (e.g. `haacked/*`) are excluded; standup is a PostHog work update, and personal tooling work isn't relevant to teammates. The `org:PostHog` qualifier in the search queries enforces this.

**Completed and Side-quest PRs** (merged since the cutoff from Step 2):

```bash
gh api search/issues --method GET -f q="author:haacked org:PostHog is:pr is:merged merged:>=${cutoff}" --jq '.items[] | {number, title, url: .html_url, repo: (.repository_url | sub(".*/repos/"; "")), merged_at: .pull_request.merged_at}'
```

`${cutoff}` is `<posted_at>` from Step 2 (a full UTC ISO timestamp like `2026-06-17T16:00:00Z`); the `merged:` qualifier accepts time-of-day, so this excludes PRs already reported and includes ones merged later the same day. Fall back to the date-only `last_standup_date` only when Step 2 returned "new". Split the merged results into **Completed** (core feature-flags product work) and **Side quests** (internal dev tooling, infra side-projects, cross-team contributions) by judging each PR's repo and title; merged side quests get state **Completed**.

Note: `gh search prs --merged` is unreliable for date filtering; it returns stale results. Always use `gh api search/issues` with the `merged:` qualifier instead, which returns accurate `merged_at` timestamps.

**Active PRs** (open PRs across all PostHog repos), including draft status:

```bash
gh api search/issues --method GET -f q="author:haacked org:PostHog is:pr is:open" --jq '.items[] | {number, title, url: .html_url, repo: (.repository_url | sub(".*/repos/"; "")), draft: .draft, updatedAt: .updated_at}'
```

Note: This single query replaces per-repo `gh pr list` calls and also covers the "recently updated" signal via `updatedAt`. Filter to items updated since `last_standup_date` to identify PRs with recent activity. Route core (feature-flags domain) open PRs to **Working on**; route non-core open PRs to **Side quests** with state **In progress**. The search API does not return review requests; for non-draft open PRs, fetch them in one Bash call:

```bash
for pr in "owner/repo#number" "owner/repo#number"; do
  repo="${pr%%#*}"; num="${pr##*#}"
  echo -e "$repo#$num\t$(gh pr view "$num" --repo "$repo" --json reviewRequests --jq '[.reviewRequests[].login] | join(",")')"
done
```

### Step 4: Compose and Save Standup Notes

Build standup content and produce two outputs: a plain text archive file and HTML for the clipboard.

#### Content Rules

**Completed items:**

- List core product (feature-flags domain) PRs merged since the cutoff from Step 2
- Use past tense; the entire description is the link text
- Use backticks (plain text) or `<code>` (HTML) for method/code names

**Combining related PRs:**

- When several PRs form one logical unit (a feature plus its rollout, a change plus its follow-ups, a primary PR plus supporting infra), combine them into a single entry instead of one bullet per PR. This applies to Completed and Side-quest items alike.
- The entry's main description links to the primary PR. Weave the related PRs in as inline links on the words that describe them, and use parentheticals for sequential follow-ups (e.g., shadow, then enable).
- In HTML each woven phrase is its own `<a>`; in the plain text archive place each link's URL in parentheses immediately after the phrase it belongs to.

**Working on items:**

- Include core (feature-flags domain) open PRs with recent activity
- Carry over items from the previous standup's "Working on", but verify each one first. For all carried-over PR URLs, check their state in one Bash call:

```bash
for pr in "owner/repo#number" "owner/repo#number"; do
  repo="${pr%%#*}"; num="${pr##*#}"
  echo -e "$repo#$num\t$(gh pr view "$num" --repo "$repo" --json state,mergedAt --jq '[.state, (.mergedAt // "")] | @tsv')"
done
```

Then apply these rules to each row:

- If **MERGED** since last standup: move to Completed (deduplicate by PR number; carry-over is the safety net for PRs the merged search may miss)
- If **CLOSED**: drop it entirely
- If **OPEN**: keep in Working on

- Determine PR status from the Step 3 data:
  - `draft: true` → link text is "draft"
  - review-requests lookup returned any reviewer → link text is "needs review"
  - Otherwise → link text is "PR"
- For non-PR work items: plain text description only

**Side-quest items:**

- List work outside the core product domain (internal dev tooling, infra side-projects, cross-team contributions)
- Label each item with its state: **In progress** for open PRs, **Completed** for merged PRs
- Same formatting as Completed items
- Omit the section entirely when there are none

**Discussion:**

- Default to a playful "nothing" variant
- Rotate between: "Nothing", "Nada", "Ain't got a thing", "Zilch", "Not a thing", "All quiet on the western front"

#### Plain Text File

Write to `new_file_path` for archival. Every item is a plain line. URLs appear in parentheses after the description.

```text
Completed:
Added `getFeatureFlagResult` method for efficient flag + payload retrieval (https://github.com/PostHog/posthog-js/pull/2920)
Added bin scripts for setup, build, and test (https://github.com/PostHog/posthog-js/pull/2824)
Added keep-first dedup for `$feature_flag_called` events (https://github.com/PostHog/posthog/pull/62793) with dedicated redis (https://github.com/PostHog/charts/pull/12362) (shadowed it (https://github.com/PostHog/charts/pull/12370) and then turned it on for team 211871 (https://github.com/PostHog/charts/pull/12428))

Working on:
Simplify readiness probe to prevent cascade failures (https://github.com/PostHog/posthog/pull/46589 - draft)
Add source field to feature flag created analytics (https://github.com/PostHog/posthog/pull/46782 - needs review)
Add HyperCache support to flag definitions cache (https://github.com/PostHog/posthog/pull/44701 - needs review)
Completing migration of celery tasks to dedicated flags queue

Side quests:
Resolved worktree path from stored value, not derived from name (Completed) (https://github.com/PostHog/code/pull/2709)
Add retry helper to the deploy script (In progress) (https://github.com/PostHog/code/pull/2741)

Discussion:
Zilch
```

#### HTML for Clipboard

Every section uses `<p><b>Header:</b></p>` followed by `<ul>`. Every item, without exception, is an `<li>` inside the `<ul>`, regardless of whether it contains a link.

```html
<p><b>Completed:</b></p>
<ul>
<li><a href="https://github.com/PostHog/posthog-js/pull/2920">Added <code>getFeatureFlagResult</code> method for efficient flag + payload retrieval</a></li>
<li><a href="https://github.com/PostHog/posthog-js/pull/2824">Added bin scripts for setup, build, and test</a></li>
<li><a href="https://github.com/PostHog/posthog/pull/62793">Added keep-first dedup for <code>$feature_flag_called</code> events</a> with <a href="https://github.com/PostHog/charts/pull/12362">dedicated redis</a> (<a href="https://github.com/PostHog/charts/pull/12370">shadowed it</a> and then turned it <a href="https://github.com/PostHog/charts/pull/12428">on for team 211871</a>)</li>
</ul>
<p><b>Working on:</b></p>
<ul>
<li>Simplify readiness probe to prevent cascade failures (<a href="https://github.com/PostHog/posthog/pull/46589">draft</a>)</li>
<li>Add source field to feature flag created analytics (<a href="https://github.com/PostHog/posthog/pull/46782">needs review</a>)</li>
<li>Add HyperCache support to flag definitions cache (<a href="https://github.com/PostHog/posthog/pull/44701">needs review</a>)</li>
<li>Completing migration of celery tasks to dedicated flags queue</li>
</ul>
<p><b>Side quests:</b></p>
<ul>
<li><a href="https://github.com/PostHog/code/pull/2709">Resolved worktree path from stored value, not derived from name</a> (Completed)</li>
<li><a href="https://github.com/PostHog/code/pull/2741">Add retry helper to the deploy script</a> (In progress)</li>
</ul>
<p><b>Discussion:</b></p>
<ul>
<li>Zilch</li>
</ul>
```

Copy to clipboard using the shared helper script:

```bash
swift ~/.dotfiles/bin/copy-html-to-clipboard.swift <<'EOF'
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
3. A message: "✅ Copied to clipboard as rich text; paste directly into Slack!"
