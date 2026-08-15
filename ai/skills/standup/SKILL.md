---
name: standup
description: Generate standup notes from GitHub PR activity. Only invoke when the user explicitly runs /standup or asks for standup notes.
model: haiku
---

# Standup Notes Generator

Generate standup notes for PostHog standups (Monday, Wednesday, Friday).

## Purpose

Every standup, you need to report:

- **Completed**: core product (feature-flags domain) PRs I authored, merged since last standup
- **Agent-authored (reviewed & landed by me)**: cloud-agent PRs (authored by `posthog[bot]`) that I reviewed, fixed up, and merged since last standup. Grouped separately so authorship is honest. Omit the section entirely when there are none.
- **Shepherded (external PRs I reviewed & merged)**: other people's PRs I shepherded to merge since last standup. Credit the contributor by handle. Omit the section entirely when there are none.
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

**Batched PR lookups:** wherever a step below needs per-PR state from `gh pr view`, batch all the PRs into one Bash loop rather than one call per PR:

```bash
for pr in "owner/repo#number" "owner/repo#number"; do
  repo="${pr%%#*}"; num="${pr##*#}"
  echo -e "$repo#$num\t$(gh pr view "$num" --repo "$repo" --json {fields} --jq '{filter}')"
done
```

**Completed and Side-quest PRs** (merged since the cutoff from Step 2):

```bash
gh api search/issues --method GET -f q="author:haacked org:PostHog is:pr is:merged merged:>=${cutoff}" --jq '.items[] | {number, title, url: .html_url, repo: (.repository_url | sub(".*/repos/"; "")), merged_at: .pull_request.merged_at}'
```

`${cutoff}` is `<posted_at>` from Step 2 (a full UTC ISO timestamp like `2026-06-17T16:00:00Z`); the `merged:` qualifier accepts time-of-day, so this excludes PRs already reported and includes ones merged later the same day. Fall back to the date-only `last_standup_date` only when Step 2 returned "new". Split the merged results into **Completed** (core feature-flags product work) and **Side quests** (internal dev tooling, infra side-projects, cross-team contributions) by judging each PR's repo and title; merged side quests get state **Completed**.

Note: `gh search prs --merged` is unreliable for date filtering; it returns stale results. Always use `gh api search/issues` with the `merged:` qualifier instead, which returns accurate `merged_at` timestamps.

**PRs you merged but didn't author**: the `author:haacked` query misses two flavors of your work entirely: cloud-agent PRs authored by `posthog[bot]` (branches like `posthog-code/*`, with docs follow-ups by `inkeep[bot]`), and other people's PRs you shepherded to merge. Run a second search for merged PRs you were involved in but didn't author:

```bash
gh api search/issues --method GET -f q="org:PostHog is:pr is:merged merged:>=${cutoff} involves:haacked -author:haacked" --jq '.items[] | {number, title, url: .html_url, repo: (.repository_url | sub(".*/repos/"; "")), author: .user.login, merged_at: .pull_request.merged_at}'
```

GitHub search has no merged-by qualifier, so batch-verify each result (`--json mergedBy --jq '.mergedBy.login'`) and keep only PRs where `mergedBy` is haacked (drop the rest — PRs you merely reviewed or commented on, then the author merged themselves).

Route the surviving PRs by author: bot-authored (login ends in `[bot]`) to **Agent-authored (reviewed & landed by me)**, human-authored to **Shepherded (external PRs I reviewed & merged)**. Neither goes in Completed. Combine each docs follow-up with the code PR it documents. Caveat: `involves:` requires authorship, assignment, a mention, or a comment; a bot PR merged without ever commenting on it won't match. If one seems missing, retry the search with `reviewed-by:haacked` in place of `involves:haacked`.

**Active PRs** (open PRs across all PostHog repos), including draft status:

```bash
gh api search/issues --method GET -f q="author:haacked org:PostHog is:pr is:open" --jq '.items[] | {number, title, url: .html_url, repo: (.repository_url | sub(".*/repos/"; "")), draft: .draft, updatedAt: .updated_at}'
```

Note: This single query replaces per-repo `gh pr list` calls and also covers the "recently updated" signal via `updatedAt`. Filter to items updated since `last_standup_date` to identify PRs with recent activity. Route core (feature-flags domain) open PRs to **Working on**; route non-core open PRs to **Side quests** with state **In progress**. The search API does not return review requests; for non-draft open PRs, batch-fetch them (`--json reviewRequests --jq '[.reviewRequests[].login] | join(",")'`).

### Step 3b: Read Open Follow-ups

Read open follow-up items for the Step 5 display:

```bash
~/.claude/skills/followup/scripts/followup-open.sh 2>/dev/null || true
```

Note each item's age from its leading date. These are personal working state for the Step 5 report only — they never go into the standup file or the clipboard HTML.

### Step 4: Compose and Save Standup Notes

Build standup content and produce two outputs: a plain text archive file and HTML for the clipboard.

#### Content Rules

**Completed items:**

- List core product (feature-flags domain) PRs merged since the cutoff from Step 2
- Use past tense; the entire description is the link text
- Use backticks (plain text) or `<code>` (HTML) for method/code names

**Agent-authored items:**

- The section header is exactly `Agent-authored (reviewed & landed by me):` and it sits directly after Completed
- List cloud-agent PRs merged by me since the cutoff (identified in Step 3), in the same format as Completed items
- Omit the section entirely when there are none

**Shepherded items:**

- The section header is exactly `Shepherded (external PRs I reviewed & merged):` and it sits directly after Agent-authored (or after Completed when there are no agent PRs)
- List other people's PRs merged by me since the cutoff (identified in Step 3), in the same format as Completed items, with the contributor credited by handle in a parenthetical: `(by @handle)`
- Omit the section entirely when there are none

**Combining related PRs:**

- When several PRs form one logical unit (a feature plus its rollout, a change plus its follow-ups, a primary PR plus supporting infra), combine them into a single entry instead of one bullet per PR. This applies to Completed, Agent-authored, Shepherded, and Side-quest items alike.
- The entry's main description links to the primary PR. Weave the related PRs in as inline links on the words that describe them, and use parentheticals for sequential follow-ups (e.g., shadow, then enable).
- In HTML each woven phrase is its own `<a>`; in the plain text archive place each link's URL in parentheses immediately after the phrase it belongs to.

**Working on items:**

- Include core (feature-flags domain) open PRs with recent activity
- Carry over items from the previous standup's "Working on", but verify each one first: batch-fetch the state of all carried-over PR URLs (`--json state,mergedAt --jq '[.state, (.mergedAt // "")] | @tsv'`), then apply these rules to each row:

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

#### Render Both Outputs

Read `~/.claude/skills/standup/templates/standup-output.md` and render the content into both skeletons: the plain text version written to `new_file_path` for archival, and the HTML version copied to the clipboard with the shared helper script:

```bash
swift ~/.dotfiles/bin/copy-html-to-clipboard.swift <<'EOF'
{generated HTML}
EOF
```

### Step 5: Report to User

Display:

1. The generated standup notes (plain text version for review)
2. The file path for easy access
3. A message: "✅ Copied to clipboard as rich text; paste directly into Slack!"
4. An **Open follow-ups** section from Step 3b: each open item with its age in days, flagging any older than 14 days (`STALE_DAYS` in followup-detect.sh). Display-only — it is not part of the standup file or the clipboard HTML. When an item references the same PR or branch as a Working on entry, note that inline.
