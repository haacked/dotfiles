---
name: sprint-planning
description: Write bi-weekly sprint planning updates for a PostHog team (defaults to Feature Flags). Automates PR fetching, sprint detection, and retro construction from the previous plan.
model: sonnet
color: pink
allowed-tools: Bash, Read, Grep, Glob
argument-hint: [archive]
---

# Sprint Planning

Generate a bi-weekly sprint planning update for a PostHog team (the Feature Flags team by default), ready to post as a GitHub comment on the sprint planning issue.

## Team Configuration

All team-specific values live in `~/.claude/skills/sprint-planning/scripts/config.sh`. The helper scripts source it automatically; the inline `gh` commands in this skill source it too, so always run them with the leading `source` line shown.

The defaults target the **Feature Flags** team:

| Variable | Default | Meaning |
| --- | --- | --- |
| `SPRINT_TEAM_SLUG` | `team-feature-flags` | GitHub team slug under the org |
| `SPRINT_TEAM_NAME` | `Feature Flags` | Display name used in prose |
| `SPRINT_PROJECT_NUMBER` | `112` | Project board number |
| `SPRINT_GOALS_URL` | `https://posthog.com/teams/feature-flags#goals` | Goals page link |
| `SPRINT_COMMENT_HEADER` | `# Team Feature Flags` | Markdown heading identifying the team's comment |
| `SPRINT_ORG` | `PostHog` | GitHub org |
| `SPRINT_REPO` | `PostHog/posthog` | Repo holding sprint issues |
| `SPRINT_FALLBACK_MEMBERS` | _(empty)_ | Space-separated handles used only if the members API fails |

Override any value with an environment variable, or edit the defaults in `config.sh`. To run the update for the **Feature Flags Platform** team instead, select that team before invoking:

```bash
export SPRINT_TEAM=platform
```

`config.sh` then resolves the Platform slug, board number (170), goals URL, and comment header. Any individual `SPRINT_*` export still overrides its value.

If the members API fails and `SPRINT_FALLBACK_MEMBERS` is empty, ask the user for the team's members.

In the output templates below, `{SPRINT_…}` placeholders refer to these config values; read them from `config.sh` (or `source` it) and substitute the resolved values before presenting output.

## Quarter Objectives

Pull the quarter goals and their statuses from the previous sprint's comment (Step 3). Carry them forward, applying any status changes the user confirms in Step 9. If no previous comment exists (the team's first sprint), ask the user for the team's current quarter objectives.

## Support Hero Shifts

Sprints are two weeks. Support hero shifts are one week. Each sprint has two support heroes, one per week. Calculate the shift dates from the sprint start date:

- Week 1: Monday of sprint week 1 through Friday of sprint week 1
- Week 2: Monday of sprint week 2 through Friday of sprint week 2

Format as `MM/DD - MM/DD` in the output.

## Arguments

- `/sprint-planning archive`: Skip the full sprint planning workflow and jump directly to archiving old Done items from the project board. When this argument is present:
  1. Run Step 1 (Detect Sprint Context) to get `sprint_start`
  2. Jump directly to Step 12 (Archive Previous Sprint's Done Items)
  3. Exit after archiving

To see what the team is currently working on (the current sprint's goals merged with live board status, grouped by member), use the `sprint-status` skill instead.

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
source ~/.claude/skills/sprint-planning/scripts/config.sh
gh api "orgs/${SPRINT_ORG}/teams/${SPRINT_TEAM_SLUG}/members" --jq '.[].login'
```

If this fails (permissions, etc.), fall back to `SPRINT_FALLBACK_MEMBERS`, or ask the user for the team's members if it is empty.

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
source ~/.claude/skills/sprint-planning/scripts/config.sh
gh project item-list "$SPRINT_PROJECT_NUMBER" --owner "$SPRINT_ORG" --format json --limit 200
```

Categorize items by status column:

- **Done** items inform the retro
- **In Progress** and **Todo** items inform the plan
- **In Review** and **Approved** items are treated as **In Progress** for planning purposes. These are PR-based items that may lack board assignees. For each, fetch the PR author with `gh pr view <number> --repo <owner/repo> --json author --jq .author.login` and use that as the assignee. Only include items whose author is a current team member.

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

Substitute the configured values into the template: use `SPRINT_COMMENT_HEADER` for the top heading, `SPRINT_GOALS_URL` for the goals link, and the board URL `https://github.com/orgs/{SPRINT_ORG}/projects/{SPRINT_PROJECT_NUMBER}` for the Plan link. The quarter goals come from Step 3 (or the user, for a first sprint), not the example below.

Use this exact format:

````markdown
```markdown
{SPRINT_COMMENT_HEADER}

**Support hero:**
- @hero1: MM/DD - MM/DD
- @hero2: MM/DD - MM/DD

**Off during the sprint:** [names or "Nobody!"]

## Quarter goals

[Link to goals]({SPRINT_GOALS_URL})

1. First quarter objective 🟡
2. Second quarter objective ⚪
3. … (carry the goals and statuses forward from Step 3)

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

[Project Board](https://github.com/orgs/{SPRINT_ORG}/projects/{SPRINT_PROJECT_NUMBER})

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
source ~/.claude/skills/sprint-planning/scripts/config.sh
gh issue comment <current_number> --repo "$SPRINT_REPO" --body "$(cat <<'EOF'
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

2. If the result is an empty array, skip silently; no prompt needed.

3. Otherwise, present the list and ask for confirmation:

   > I found {N} items in the Done column that were completed before this sprint ({sprint_start}). Would you like me to archive them to keep the board clean?
   >
   > {list of items with titles and closed dates}

4. If the user confirms, archive each item:

   ```bash
   source ~/.claude/skills/sprint-planning/scripts/config.sh
   gh project item-archive "$SPRINT_PROJECT_NUMBER" --owner "$SPRINT_ORG" --id <item-id>
   ```

## Formatting Rules

The output template in Step 10 is the authoritative format reference. These rules cover non-obvious behavior not visible in the template:

- **No status emojis on retro PR links**: the retro lists shipped work, so checkmarks or status indicators are not needed on individual PR entries
- **Always include a Side quests section in the Plan**: include it even as a placeholder if there are no side quests
- **Never post without explicit user confirmation**: always ask before running the `gh issue comment` command
