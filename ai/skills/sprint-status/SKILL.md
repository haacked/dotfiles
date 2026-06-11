---
name: sprint-status
description: Produce a per-team-member sprint status checklist for the current sprint (each member's planned goals with a done / in-progress / not-started marker) and copy it to the clipboard as Slack-ready rich text, or emit Slack markdown with the `slack` argument. Defaults to the Feature Flags team; pass `platform` for Feature Flags Platform.
allowed-tools: Bash, Read
argument-hint: "[platform] [slack]"
---

# Sprint Status

Show where every team member stands on their goals for the **current** sprint, then copy the result to the clipboard as rich text that pastes cleanly into Slack — or, with the `slack` argument, emit Slack markdown text instead (for headless runs where nobody is at the keyboard to paste).

This skill reuses the `sprint-planning` helper scripts for sprint detection, team config, the sprint plan comment, and board data, plus the shared `copy-html-to-clipboard.swift` helper. It does not post anything to GitHub or Slack.

## Team Configuration

Team-specific values come from the shared `sprint-planning` config at
`~/.claude/skills/sprint-planning/scripts/config.sh`. The defaults target the **Feature Flags** team (project board 112).

If the argument is `platform`, select the **Feature Flags Platform** team before sourcing anything:

```bash
export SPRINT_TEAM=platform
```

`config.sh` then resolves that team's slug, board number, goals URL, and comment header. Exporting the variable (not just setting it) is what carries the choice into the helper scripts, which run as separate processes.

Note: the two flags teams merged into **Feature Flags** (board 112). Prefer the default unless the user explicitly asks for the Platform board.

## Status Markers

| Marker | Meaning | Source |
| --- | --- | --- |
| ✅ | Done | PR `MERGED`, or Issue `CLOSED` (stateReason `COMPLETED` or null) |
| 🔄 | In progress / in review | PR `OPEN` (suffix `in review`, or `draft` if `isDraft`), or Issue `OPEN` that the board marks `In Progress` |
| ⬜ | Not started | Issue `OPEN` not marked `In Progress` on the board |
| 🚫 | Won't do / dropped | Issue `CLOSED` with stateReason `NOT_PLANNED` or `DUPLICATE` (suffix `closed, not planned`), or PR `CLOSED` without merge (suffix `closed`) |

A member's count is `✅ / total planned items`.

## Your Task

Gather all data automatically, then render and copy. Do not prompt the user unless a step fails and the fallbacks below don't resolve it.

### Step 1: Resolve Team Config

If the argument is `platform`, run `export SPRINT_TEAM=platform` first. Then source the shared config so your inline commands and the helper scripts agree:

```bash
source ~/.claude/skills/sprint-planning/scripts/config.sh
```

### Step 2: Detect the Current Sprint

```bash
~/.claude/skills/sprint-planning/scripts/detect-sprint.sh
```

Tab-separated fields; you need `current_number` and `current_title`.

### Step 3: Determine the Current User

```bash
gh api user --jq .login
```

This user's section sorts first and is marked `(you)`. If it fails, fall back to matching `git config user.email` against the team handles.

### Step 4: Fetch the Current Sprint Plan

```bash
~/.claude/skills/sprint-planning/scripts/fetch-previous-comment.sh <current_number>
```

- If a comment is returned, parse the **Plan** section. Each `@member` heading is followed by their planned items; each item is a `[title](url)` link or plain text. These items are the goals. Capture, per member: the title, the URL (if any), and which member owns it.
- If the result is `NOT_FOUND`, there's no sprint plan yet. Fall back to board items only: run Step 5, group `In Progress` + `Todo` items by assignee, and treat every item's marker from its board status (`In Progress` → 🔄, `Todo` → ⬜). Skip the plan-based parsing.

### Step 5: Fetch Board Statuses

```bash
~/.claude/skills/sprint-planning/scripts/fetch-board-goals.sh
```

Returns a JSON array of `In Progress` / `Todo` items with `url`, `status`, and `assignees`. Two uses:

1. Decide 🔄 vs ⬜ for **open issues** in the plan: an open issue whose URL appears with status `In Progress` is 🔄, otherwise ⬜. (The `assignees` field is also what the Step 4 `NOT_FOUND` fallback groups by.)
2. Surface board work that isn't in the plan. A board item whose URL or issue/PR number matches no plan item is "new": it renders under its assignee's **New (not in sprint plan)** subsection, or under a final **Unassigned** section when it has no assignee. Its marker comes from board status (`In Progress` → 🔄, `Todo` → ⬜).

### Step 6: Resolve Item Statuses

Collect every plan item URL (one per line) and pipe them to the resolver:

```bash
~/.claude/skills/sprint-status/scripts/resolve-item-status.sh <<'EOF'
<url1>
<url2>
…
EOF
```

It returns a JSON array with `state`, `isDraft`, `stateReason`, and `title` per URL via a single batched GraphQL call. Map each item to a marker using the **Status Markers** table, combining this output with the board status from Step 5 for open issues. Plain-text plan items with no URL default to ⬜ unless the user has said otherwise.

### Step 7: Render and Copy

**Slack mode**: if the `slack` argument was given, skip the HTML and clipboard entirely. Render the same content (same sections, ordering, and Display rules below) as Slack markdown and emit it as your final output: a single-asterisk `*bold*` summary line, then per member a `*@handle: x/y*` line followed by `-` bullets, each starting with the marker emoji, then the `[title](url)` link, then the optional status suffix in parentheses. Skip Step 8.

Otherwise, build the HTML below and copy it with the shared helper, which sets the `public.html` clipboard flavor that Slack reads (a plain-markdown paste does **not** render; it must be this rich-text path):

```bash
swift ~/.dotfiles/bin/copy-html-to-clipboard.swift <<'EOF'
<html-here>
EOF
```

**HTML structure**: a bold summary line, then per member a bold header and a `<ul>`. Every item is an `<li>` starting with the marker emoji, then the linked title, then an optional status suffix in parentheses. HTML-escape `&`, `<`, and `>` in titles (and the `href`) so a stray character in a GitHub title can't corrupt the pasted output:

```html
<p><b>{SPRINT_TEAM_NAME}: {current_title} ({done_total}/{grand_total} done)</b></p>
<p><b>@you: 6/10</b></p>
<ul>
<li>✅ <a href="https://github.com/PostHog/posthog/pull/60550">add updated_at to Project model</a></li>
<li>🔄 <a href="https://github.com/PostHog/posthog/pull/60569">strip non-allowlisted $feature_flag_called properties</a> (in review)</li>
<li>⬜ <a href="https://github.com/PostHog/posthog/issues/60581">Orphaned person profiles created via $feature_flag_called event</a></li>
</ul>
<p><b>@teammate: 1/8</b></p>
<ul>
<li>✅ <a href="...">…</a></li>
<li>⬜ <a href="...">…</a></li>
</ul>
<p><i>New (not in sprint plan):</i></p>
<ul>
<li>🔄 <a href="...">…</a></li>
</ul>
<p><b>Unassigned</b></p>
<ul>
<li>⬜ <a href="...">…</a></li>
</ul>
```

**Display rules:**

- Current user's section first, header ending in `(you)` (after a space); other members alphabetical.
- Order each member's items: ✅ first, then 🔄, then ⬜, then 🚫.
- Items with a URL are links; plain-text items render as plain `<li>` text with the marker.
- After a member's planned items, add a **New (not in sprint plan):** subsection for board items assigned to them that no plan item matched (marker from board status). Omit it when empty.
- End with an **Unassigned** section for board items with no assignee that aren't in any plan. Omit it when empty.
- Only include members who have at least one planned or new item.
- The member count (`6/10`) covers planned items only: `{done}` ✅ over total planned. New items are not counted. The summary line's `{done_total}` / `{grand_total}` likewise count planned items across everyone.

### Step 8: Report

Show the user a plain-markdown rendering of the same list for in-terminal review, grouped by member with the same ordering: render `- [x]` for ✅ and 🚫, `- [ ]` for 🔄 and ⬜, keeping the status suffix and `[title](url)` links. Then confirm:

> ✅ Copied to clipboard as rich text; paste directly into Slack.

## Notes

- This is read-only. Never post the result to GitHub or Slack; the user pastes it themselves.
- Issue "Open" only distinguishes started from not-started via the board's `In Progress` column, so 🔄 vs ⬜ is best-effort for issues without board status.
