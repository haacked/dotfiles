---
name: sprint-planning
description: Write bi-weekly sprint planning updates for the Feature Flags Platform team. Automates PR fetching, sprint detection, and retro construction from the previous plan.
model: sonnet
color: pink
allowed-tools: Bash, Read, Grep, Glob
argument-hint: [archive|goals]
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

## Arguments

- `/sprint-planning archive` — Skip the full sprint planning workflow and jump directly to archiving old Done items from the project board. When this argument is present:
  1. Run Step 1 (Detect Sprint Context) to get `sprint_start`
  2. Jump directly to Step 12 (Archive Previous Sprint's Done Items)
  3. Exit after archiving

- `/sprint-planning goals` — Show what the team is currently working on by merging the current sprint plan with project board data, grouped by assignee. When this argument is present:
  1. Run Step G1 (Fetch Team Members)
  2. Run Step G2 (Determine Current User)
  3. Run Step G3 (Fetch Current Sprint Plan)
  4. Run Step G4 (Fetch Board Goals)
  5. Run Step G5 (Merge and Display)
  6. Exit after displaying

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

For each team member, fetch their merged PRs during the **previous** sprint period. Issue all fetch calls in parallel (multiple Bash tool calls in a single response) to minimize wall-clock time:

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
gh issue comment <current_number> --repo PostHog/posthog --body "$(cat <<'EOF'
<the markdown>
EOF
)"
```

### Step 12: Archive Previous Sprint's Done Items

After posting the comment (or if the user declines to post), offer to clean up the project board by archiving Done items from previous sprints.

1. Run the helper script to find archivable items:

```bash
~/.claude/skills/sprint-planning/scripts/archive-done-items.sh <sprint_start>
```

2. If the result is an empty array, skip silently — no prompt needed.

3. Otherwise, present the list and ask for confirmation:

> I found {N} items in the Done column that were completed before this sprint ({sprint_start}). Would you like me to archive them to keep the board clean?
>
> {list of items with titles and closed dates}

4. If the user confirms, archive each item:

```bash
gh project item-archive 170 --owner PostHog --id <item-id>
```

## Goals Workflow

These steps apply when the `goals` argument is provided. They run independently of the main sprint planning workflow.

### Step G1: Fetch Team Members

Follow Step 2 (Fetch Team Members) from the main workflow.

### Step G2: Determine Current User

```bash
gh api user --jq .login
```

This user's section is highlighted in the output. If the API call fails, fall back to the output of `git config user.email` and match against team member handles.

### Step G3: Fetch Current Sprint Plan

1. Detect the current sprint using Step 1 (Detect Sprint Context) from the main workflow.

2. Fetch the team's comment from the current sprint issue:

```bash
~/.claude/skills/sprint-planning/scripts/fetch-previous-comment.sh <current_number>
```

3. If the result is "NOT_FOUND", skip this step (no sprint plan exists yet). The output will rely solely on board data from Step G4.

4. If a comment is found, parse the **Plan** section to extract each team member's planned items. Each item may be plain text or a `[title](url)` link.

### Step G4: Fetch Board Goals

Run the helper script to fetch In Progress and Todo items with assignee data:

```bash
~/.claude/skills/sprint-planning/scripts/fetch-board-goals.sh
```

This returns a JSON array of items, each with `id`, `title`, `status`, `url`, `type`, `number`, and `assignees` fields.

### Step G5: Merge and Display

Merge the sprint plan (Step G3) with the project board (Step G4) into a single view per team member.

**Merge strategy:**

1. Start from the sprint plan items as the baseline for each person.
2. For each board item, check if it matches a plan item by URL, issue/PR number, or keyword similarity in the title.
3. Matched items: use the board item's status (In Progress / Todo) and URL, preserving the plan's item description.
4. Unmatched plan items (not on the board): include as-is from the plan, without a status subheading.
5. Unmatched board items (not in the plan): append under a **"New (not in sprint plan):"** subheading.
6. If no sprint plan exists (Step G3 returned NOT_FOUND), display board items only, grouped by status as before.

**Output format:**

```markdown
## Team Goals - Feature Flags Platform

[Project Board](https://github.com/orgs/PostHog/projects/170)

**--> @currentuser** (you)

**In Progress:**
- [Item from plan that's in progress on board](url)

**Todo:**
- [Item from plan that's todo on board](url)

**Other planned:**
- Item from plan not on board

**New (not in sprint plan):**
- [Board item not in plan](url) - In Progress

---

@teammate

**In Progress:**
- [Their item](url)

---

### Unassigned
- [Orphaned item](url) - In Progress
- Draft board item title - Todo
```

**Display rules:**

- Current user appears first with `**-->**` prefix and `(you)` suffix
- Other team members in alphabetical order
- Items with URLs use `[title](url)` links
- DraftIssues (no URL) show plain text title
- Unassigned items appear at bottom in a separate section
- Items with multiple assignees appear under each assignee
- Status subsections only shown if items exist for that status
- Only show team members who have at least one item assigned
- Side quests from the sprint plan appear under their own heading per person

## Formatting Rules

The output template in Step 10 is the authoritative format reference. These rules cover non-obvious behavior not visible in the template:

- **No status emojis on retro PR links** — the retro lists shipped work, so checkmarks or status indicators are not needed on individual PR entries
- **Always include a Side quests section in the Plan** — include it even as a placeholder if there are no side quests
- **Never post without explicit user confirmation** — always ask before running the `gh issue comment` command
