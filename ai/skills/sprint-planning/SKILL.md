---
name: sprint-planning
description: Write bi-weekly sprint planning updates for the Feature Flags Platform team. Automates PR fetching, sprint detection, and retro construction from the previous plan.
model: sonnet
color: pink
allowed-tools: Bash, Read, Grep, Glob
---

# Sprint Planning - Feature Flags Platform

Generate a bi-weekly sprint planning update for the Feature Flags Platform team, ready to post as a GitHub comment on the sprint planning issue.

## Team Configuration

**Team:** Feature Flags Platform
**GitHub Team:** `PostHog/team-flags-platform`
**Project Board:** [PostHog Project 170](https://github.com/orgs/PostHog/projects/170)
**Goals Page:** [posthog.com/teams/flags-platform#goals](https://posthog.com/teams/flags-platform#goals)

**Fallback members** (used only if the GitHub API call fails):

- @haacked
- @dmarticus
- @matheus-vb
- @patricio-posthog

## Q1 2026 Objectives

Unless told otherwise, use these objectives:

1. Isolated flags-specific infra 🟡
2. Load testing framework ⚪
3. Sub-100ms P99, consistent response 🟡
4. Decouple flag evaluation from persons DB 🟡
5. Delete all `/decide` code 🟢
6. Split `remote_config` from `/flags` 🟢
7. Get `/local_evaluation` in a good state 🟡

## Support Hero Shifts

Sprints are two weeks. Support hero shifts are one week. Each sprint has two support heroes, one per week. Calculate the shift dates from the sprint start date:

- Week 1: Monday of sprint week 1 through Friday of sprint week 1
- Week 2: Monday of sprint week 2 through Friday of sprint week 2

Format as `MM/DD - MM/DD` in the output.

## Your Task

Follow these steps in order. Gather as much data automatically as possible before asking the user anything.

### Step 1: Detect Sprint Context

Run the helper script to find the current and previous sprint issues:

```bash
~/.claude/skills/sprint-planning/scripts/detect-sprint.sh
```

This returns tab-separated fields:
`current_number\tcurrent_title\tsprint_start\tsprint_end\tprev_number\tprev_title\tprev_start\tprev_end`

Store all these values. You need:

- `current_number` and `current_title` for the issue to post on
- `sprint_start` and `sprint_end` for the PR date range
- `prev_number` for fetching the previous comment
- `prev_start` and `prev_end` for the previous sprint's PR date range

### Step 2: Fetch Team Members

```bash
gh api orgs/PostHog/teams/team-flags-platform/members --jq '.[].login'
```

If this fails (permissions, etc.), fall back to the hardcoded list above.

### Step 3: Fetch Previous Sprint Comment

```bash
~/.claude/skills/sprint-planning/scripts/fetch-previous-comment.sh <prev_number>
```

If the result is "NOT_FOUND" (e.g., the team's first sprint), skip the plan-first retro approach entirely. You'll build the retro purely from merged PRs and project board items instead, confirmed with the user.

If the result is not "NOT_FOUND", parse the comment to extract:

- The **Plan** section from the previous sprint (this becomes the retro skeleton)
- Each team member's planned items
- The quarter goal statuses

### Step 4: Fetch Merged PRs

For each team member, fetch their merged PRs during the **previous** sprint period:

```bash
~/.claude/skills/sprint-planning/scripts/fetch-team-prs.sh <username> <prev_start> <prev_end>
```

Store all PR data per team member.

### Step 5: Fetch Project Board Items

```bash
gh project item-list 170 --owner PostHog --format json --limit 200
```

Categorize items by status column:

- **Done** items inform the retro
- **In Progress** and **Todo** items inform the plan

Each item's `content.url` field contains the issue or PR URL. Preserve these for linking in the output.

### Step 6: First Prompt - Context

Now that you have all the automated data, ask the user:

> I'm writing the sprint planning update for **{current_title}** (#{current_number}).
>
> Team members: {list from Step 2}
>
> Quick questions before I build the draft:
>
> 1. Who are the two support heroes this sprint? (Week 1: {sprint_start Mon-Fri}, Week 2: {following Mon-Fri})
> 2. Is anyone off during the sprint?

Wait for the user's response before continuing.

### Step 7: Build Retro

There are two paths depending on whether a previous sprint comment was found.

Path A - Previous plan exists (plan-first retro):

Start from what was **planned**, not what was shipped.

Extract previous plan items: From the previous sprint comment (Step 3), parse each person's planned items. These become the retro checklist.

Auto-resolve statuses: For each planned item, search the merged PRs (Step 4) for a match by:

- Issue number or PR number overlap
- Keyword similarity in titles
- Explicit references

If a matching merged PR is found, mark the item as done with the PR link.

Identify side quests: Any merged PRs that don't map to a planned item are candidate "side quests" or unplanned work.

Path B - No previous plan (first sprint or NOT_FOUND):

Build the retro entirely from merged PRs and project board "Done" items. Group each person's PRs by theme and present them for confirmation.

### Step 8: Second Prompt - Retro Review

If previous plan exists (Path A), present the reconciled retro per person:

> Here's what I've reconstructed from last sprint's plan vs. what shipped:
>
> **@member1**
>
> - ✅ Planned item 1 → [PR title](url)
> - ✅ Planned item 2 → [PR title](url)
> - ❓ Planned item 3 → no matching PR found
>
> **Unmatched PRs (side quests?):**
>
> - [PR title](url)
>
> Questions:
>
> 1. For items marked ❓, what's the status? (done, in progress, blocked, cancelled)
> 2. Which unmatched PRs should I include as side quests?
> 3. Anything else to add or correct?

If no previous plan (Path B), present merged PRs grouped by person and theme:

> Here's what I found shipped during the sprint:
>
> **@member1**
>
> - [PR title](url)
> - [PR title](url)
>
> **@member2**
>
> - [PR title](url)
>
> Questions:
>
> 1. Are these groupings and themes accurate?
> 2. Anything missing that didn't result in PRs?
> 3. Anything to exclude?

Wait for the user's response.

### Step 9: Third Prompt - Plan and Objectives

Present project board items as a draft plan:

> Here's the plan I've drafted from the project board:
>
> **High priority:**
> @member1 - item1, item2
> @member2 - item3
>
> **Side quests:**
>
> - item4
>
> Questions:
>
> 1. Any adjustments to the plan?
> 2. Any changes to quarter goal statuses?

Wait for the user's response.

### Step 10: Generate the Update

Compose the final sprint update using all gathered and confirmed data. Write a short narrative summary paragraph for the retro that captures the team's key themes and accomplishments.

**IMPORTANT**: Output the update as raw markdown inside a code block so the user can copy/paste it directly into GitHub.

Use this exact format:

````markdown
```markdown
# Team Feature Flags Platform

**Support hero:**
- @hero1: MM/DD - MM/DD
- @hero2: MM/DD - MM/DD

**Off during the sprint:** [names or "Nobody!"]

## Quarter goals

[Link to goals](https://posthog.com/teams/flags-platform#goals)

1. Isolated flags-specific infra 🟡
2. Load testing framework ⚪
3. Sub-100ms P99, consistent response 🟡
4. Decouple flag evaluation from persons DB 🟡
5. Delete all `/decide` code 🟢
6. Split `remote_config` from `/flags` 🟢
7. Get `/local_evaluation` in a good state 🟡

<details>
⚪ = Not Started
🟡 = In Progress
🟢 = Completed
🔴 = Won't complete
🔵 = Abandoned
</details>

## Retro

Narrative summary paragraph describing the team's key accomplishments and themes from the sprint.

<details>

@member1

**Theme name:**
- [exact PR title](url)
- [exact PR title](url)

**Another theme:**
- [exact PR title](url)

@member2

**Theme name:**
- [exact PR title](url)

</details>

## Plan

[Project Board](https://github.com/orgs/PostHog/projects/170)

### High priority

@member1
- [Work item description](https://github.com/PostHog/posthog/issues/123)
- [Another work item](https://github.com/PostHog/posthog/pull/456)

@member2
- [Work item description](https://github.com/PostHog/posthog/issues/789)

### Side quests

- [Side quest item](https://github.com/PostHog/posthog/issues/101)
- Plain text item if no link available
```
````

### Step 11: Offer to Post

After showing the output, ask:

> Would you like me to post this as a comment on #{current_number}?

If the user confirms, post with:

```bash
gh issue comment <current_number> --repo PostHog/posthog --body '<the markdown>'
```

## Formatting Rules

Follow these rules exactly:

1. **Team member handles are NOT headings** - Use `@username` on its own line, not `### @username`
2. **PR links use the EXACT PR title** - Include the full title as it appears on GitHub
3. **Hyperlink format** - Always use `[Title](URL)` format for both retro PRs and plan items, never bare URLs
4. **No status emojis on PR links** - The retro lists shipped PRs, so no checkmarks needed
5. **Group PRs by theme** - Use bold text like `**Cache performance:**` to group related PRs
6. **Retro details are collapsed** - Wrap the per-person PR breakdown in `<details>` tags
7. **Retro has a narrative summary** - A short paragraph above the details summarizing the sprint
8. **Plan section mirrors retro structure** - `@username` on its own line, then bullet points
9. **Always include Side quests section** - Even if just a placeholder
10. **Link plan and retro items** - If an issue or PR URL is available, link the item title to it
11. **Output as raw markdown** - Always wrap the final output in a code block for copy/paste

## What You Do NOT Do

- Make up work items or accomplishments
- Guess at what people worked on without data
- Assume objective statuses without asking
- Skip fetching PRs from GitHub
- Use `### @username` headings
- Strip or shorten PR titles
- Add status emojis to PR links in the retro
- Forget the Side quests section
- Output rendered markdown instead of a code block
- Post the comment without explicit user confirmation
