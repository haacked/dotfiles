---
name: standup
description: Generate standup notes from GitHub PR activity. Only invoke when the user explicitly runs /standup or asks for standup notes.
disable-model-invocation: true
model: haiku
metadata:
  execution-tier: fast
---

# Standup Notes Generator

Generate standup notes for PostHog standups (Monday, Wednesday, Friday).

## Purpose

Every standup, you need to report:

- **Completed**: core product (feature-flags domain) PRs I authored, merged since last standup
- **Agent-authored (reviewed & landed by me)**: cloud-agent PRs (authored by `posthog[bot]`) that I reviewed, fixed up, and merged since last standup. Grouped separately so authorship is honest. Omit the section entirely when there are none.
- **Shepherded (external PRs I reviewed & merged)**: outside contributors' PRs I shepherded to merge since last standup. Credit the contributor by handle. Excludes teammates on the feature-flags team, who report their own work in the same standup. Omit the section entirely when there are none.
- **Working on**: PRs with recent activity + items from last standup not yet done
- **Side quests**: work outside the team's core product domain (internal dev tooling, infra side-projects, or cross-team contributions), each labeled with its state (In progress / Completed). Omit the section entirely when there are none.
- **Discussion**: Usually something playful ("Nothing", "Nada", "Ain't got a thing")

## Your Task

### Step 1: Get Date Context

Run the helper script to get standup dates:

```bash
scripts/standup-dates.sh
```

This returns tab-separated: `<today>\t<last_standup_date>\t<new_file_path>`

Store these values:

- `today` - Today's date (for the new standup file)
- `last_standup_date` - When the previous standup was (for PR queries)
- `new_file_path` - Where to write the new standup notes

### Step 2: Find Previous Standup Notes

Run the helper script to find previous standup notes:

```bash
scripts/standup-find.sh
```

This returns tab-separated: `<status>\t<path>\t<date>\t<posted_at>`

If `status` is "found", read the previous standup notes at `<path>` and note the "Working on" items that have no PR URL. Step 4 carries them over. Step 3 handles the PR items.

### Step 3: Gather PR Activity

**Only PRs from `PostHog/*` repos count.** Personal repos (e.g. `haacked/*`) are excluded; standup is a PostHog work update, and personal tooling work isn't relevant to teammates.

Run every lookup that decides which PRs the notes list in one call, passing `last_standup_date` from Step 1:

```bash
scripts/standup-gather.sh "<last_standup_date>"
```

Never run those lookups by hand with `gh`, `scripts/standup-search.sh`, or `scripts/standup-pr-view.sh`. If the script exits non-zero, do not retry it and do not replace it with manual lookups. Write down the command and the error it printed, compose partial notes from what you already have, skip the save in Step 4, and report the failed command and its error in Step 5.

The script prints one JSON object:

- `cutoff`: the merge cutoff. It is the previous notes file's modified time (`<posted_at>` from Step 2), so PRs merged after the last posting are picked up even when they landed the same day, and PRs merged before it aren't double-counted. It is `last_standup_date` when Step 2 returned "new".
- `merged_authored`: my PRs merged since the cutoff. Split them into **Completed** (core feature-flags product work) and **Side quests** (internal dev tooling, infra side-projects, cross-team contributions) by judging each PR's repo and title; merged side quests get state **Completed**.
- `agent_authored`: cloud-agent PRs (authored by `posthog[bot]`, with docs follow-ups by `inkeep[bot]`) merged since the cutoff that I merged or approved. They go in **Agent-authored (reviewed & landed by me)**.
- `shepherded`: outside contributors' PRs merged since the cutoff that I merged or approved. Feature-flags teammates' PRs are already removed, because teammates report their own work in the same standup. They go in **Shepherded (external PRs I reviewed & merged)**.
- `open`: my open PRs updated since `last_standup_date`, with `draft` and `review_requests`. Route them by domain: core (feature-flags domain) PRs go to **Working on**; non-core PRs go to **Side quests** with state **In progress**.
- `carry_over`: the `state` and `merged_at` of each PR in the previous notes' "Working on" section. Step 4 applies these.
- `must_list`: every PR URL the notes must contain, written as the full `https://github.com/...` URL exactly as it appears in the JSON. The save script in Step 4 refuses to save notes that leave one out.

Neither `agent_authored` nor `shepherded` PRs go in Completed. Put each docs follow-up on the same line as the code PR it documents, and keep both PR URLs on that line, because the save script checks every URL in `must_list`.

### Step 3b: Read Open Follow-ups

Read open follow-up items for the Step 5 display:

```bash
~/.dotfiles/ai/skills/followup/scripts/followup-open.sh 2>/dev/null || true
```

Note each item's age from its leading date. These are personal working state for the Step 5 report only — they never go into the standup file or the clipboard HTML.

### Step 4: Compose and Save Standup Notes

Build standup content and produce two outputs: a plain text archive file and HTML for the clipboard.

#### Content Rules

**Completed items:**

- List core product (feature-flags domain) PRs from `merged_authored` in Step 3, plus carried-over PRs that are now merged
- Use past tense; the entire description is the link text
- Use backticks (plain text) or `<code>` (HTML) for method/code names

**Agent-authored items:**

- The section header is exactly `Agent-authored (reviewed & landed by me):` and it sits directly after Completed
- List cloud-agent PRs merged by me since the cutoff (identified in Step 3), in the same format as Completed items
- Omit the section entirely when there are none

**Shepherded items:**

- The section header is exactly `Shepherded (external PRs I reviewed & merged):` and it sits directly after Agent-authored (or after Completed when there are no agent PRs)
- Outside contributors only. A PR whose author appears in the feature-flags team roster never lands here; it is dropped in Step 3
- List other people's PRs merged by me since the cutoff (identified in Step 3), in the same format as Completed items, with the contributor credited by handle in a parenthetical: `(by @handle)`
- Omit the section entirely when there are none

**Combining related PRs:**

- When several PRs form one logical unit (a feature plus its rollout, a change plus its follow-ups, a primary PR plus supporting infra), combine them into a single entry instead of one bullet per PR. This applies to Completed, Agent-authored, Shepherded, and Side-quest items alike.
- The entry's main description links to the primary PR. Weave the related PRs in as inline links on the words that describe them, and use parentheticals for sequential follow-ups (e.g., shadow, then enable).
- In HTML each woven phrase is its own `<a>`; in the plain text archive place each link's URL in parentheses immediately after the phrase it belongs to.

**Working on items:**

- Include the core (feature-flags domain) PRs from `open` in Step 3
- Carry over items from the previous standup's "Working on". Apply these rules to each `carry_over` row from Step 3, and carry over the non-PR items from Step 2 as they are:

- If **MERGED**: move to Completed (deduplicate by PR number; carry-over is the safety net for PRs the merged search may miss)
- If **CLOSED**: drop it entirely
- If **OPEN**: keep in Working on

- Determine PR status from the Step 3 data:
  - `draft: true` → link text is "draft"
  - `review_requests` is not empty → link text is "needs review"
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

#### Render Both Outputs

Before rendering, apply the `plain-writing` skill in technical mode to the descriptions you wrote. Keep PR titles, section names, status labels, and attribution exactly as generated. Keep the Discussion line exactly as chosen.

Read `templates/standup-output.md` and render the content into both skeletons: the plain text version for the archive file, and the HTML version for the clipboard.

Save the plain text version through the save script. Never write `new_file_path` any other way:

```bash
scripts/standup-save.sh "<new_file_path>" <<'EOF'
{generated plain text}
EOF
```

The next run uses that file's modified time as its merge cutoff, so a PR the notes leave out would never appear in any standup. The script refuses to write the file, exits 1, and says why when the last Step 3 run failed, when the newest notes file changed after Step 3 ran (an earlier save included), or when the notes leave out a URL from `must_list`. When the refusal says the notes leave out PRs, add each listed PR to the right section and run the save once more. If the second save is refused, stop and report the reason. For any other refusal, report the reason the script printed and the Step 3 error when there was one, and do not retry the save.

Copy the HTML version to the clipboard with the shared helper script:

```bash
swift ~/.dotfiles/bin/copy-html-to-clipboard.swift <<'EOF'
{generated HTML}
EOF
```

### Step 5: Report to User

Display:

1. The generated standup notes (plain text version for review)
2. The file path for easy access, or, when the file was not written, the failed command and the error it printed (or the reason the save script gave) and a line saying the archive file was not written
3. A message: "✅ Copied to clipboard as rich text; paste directly into Slack!"
4. An **Open follow-ups** section from Step 3b: each open item with its age in days, flagging any older than 14 days (`STALE_DAYS` in followup-detect.sh). Display-only — it is not part of the standup file or the clipboard HTML. When an item references the same PR or branch as a Working on entry, note that inline.
