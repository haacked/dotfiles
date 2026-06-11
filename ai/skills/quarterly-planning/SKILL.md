---
name: quarterly-planning
description: Draft quarterly goals for a PostHog team (defaults to Feature Flags). Gathers supporting docs (RFCs, strategy docs, Slack threads), mines open issues by label, clusters them into themes, walks the HOGS framework, and produces goals in PostHog's format. Use when planning a new quarter's objectives.
color: purple
argument-hint: [themes]
model: fable
---

# Quarterly Planning

Help a PostHog team (the **Feature Flags** team by default) draft its quarterly goals. The skill gathers the user's supporting documents (RFCs, strategy docs, Slack threads), mines open issues across the team's labels, clusters them into themes, reflects on last quarter, walks PostHog's HOGS framework, and drafts objectives in the handbook's goal format ready to paste into a posthog.com goals PR.

This follows PostHog's goal-setting process: <https://posthog.com/handbook/company/goal-setting>. Read it if you need the cadence and rationale; the relevant mechanics are inlined below.

## Team Configuration

All team-specific values live in `~/.claude/skills/quarterly-planning/scripts/config.sh`. The helper script sources it automatically; the inline `gh` commands here source it too, so run them with the leading `source` line shown.

The defaults target the **Feature Flags** team:

| Variable | Default | Meaning |
| --- | --- | --- |
| `QPLAN_ORG` | `PostHog` | GitHub org |
| `QPLAN_REPO` | `PostHog/posthog` | Repo whose issues are mined |
| `QPLAN_TEAM_SLUG` | `team-feature-flags` | GitHub team slug (members API) |
| `QPLAN_TEAM_NAME` | `Feature Flags` | Display name used in prose |
| `QPLAN_LABELS` | `team/feature-flags feature/feature-flags feature/cohorts feature/feature-management` | Labels to mine (OR'd, de-duplicated) |
| `QPLAN_GOALS_URL` | `https://posthog.com/teams/feature-flags` | Last quarter's goals |
| `QPLAN_HANDBOOK_URL` | `https://posthog.com/handbook/company/goal-setting` | Goal-setting process |

Override any value with an environment variable, or edit `config.sh`. To plan for the **Feature Flags Platform** team instead, select that team before invoking:

```bash
export QPLAN_TEAM=platform
```

`config.sh` then resolves the Platform slug, name, labels, and goals URL. Any individual `QPLAN_*` export still overrides its value.

## PostHog's Goal Format

Goals at PostHog are output-based and few. The handbook principles that shape the draft:

- **As few objectives as possible.** Prefer 2-4 strong objectives over a long list.
- **Simple and unambiguous.** It must be obvious whether the objective was hit.
- **Output-based, not metric-chasing.** Ship tangible things; the overarching objective matters more than any single deliverable.
- **Ambitious yet achievable.** Missing a hard goal while doing great work en route is acceptable; repeatedly missing means the goal was miscalibrated.

Each objective uses this structure:

- **Objective** — a clear, ambitious one-line statement.
- **Rationale** — why it matters now (the motivation).
- **What we'll ship** — concrete deliverables, each with an owner.
- **Success metric** — the outcome that signals it's done.

## Arguments

- `/quarterly-planning themes` — Stop after Step 4 (issue mining + theme clustering). Produces the theme map and exits without drafting goals or running HOGS. Useful for a quick "what's in the backlog" survey. Supporting-context gathering (Step 2, including infrastructure work) still runs unless the user has none.

## Your Task

Follow these steps in order. Gather and present the automated data before asking the user anything.

### Step 1: Confirm Scope

Resolve the config and state the plan back to the user in one line:

```bash
source ~/.claude/skills/quarterly-planning/scripts/config.sh
echo "Team: $QPLAN_TEAM_NAME | Repo: $QPLAN_REPO | Labels: $QPLAN_LABELS"
```

Ask which quarter is being planned (e.g. "Q3 2026") if the user hasn't said. Everything else is automated.

### Step 2: Gather Supporting Context

Backlog issues are only one input. Strategy docs, RFCs, leadership planning docs, and Slack threads carry the _direction_ that issues don't — and infrastructure, platform, and tech-debt work frequently has **no issue at all**. Gather both before mining issues.

**2a. Supporting documents.** Prompt the user:

> Before I mine the backlog, share any supporting documents or links that should inform this quarter's goals — RFCs, strategy or planning docs, a Slack thread, last quarter's retro, competitive notes, etc. Paste links or text. (Reply "none" to skip.)

Wait for the user's reply. For each link they provide, pull the content with whatever tool fits the source, then summarize it back so the user can confirm you read the right thing:

- **GitHub** (issues, PRs, RFC repos like `PostHog/requests-for-comments-internal`): `gh pr view <url> --json title,body,comments` or `gh issue view <url>`. Private repos work as long as the user's `gh` auth has access.
- **Slack** (`posthog.slack.com/archives/<channel>/p<ts>`): use the Slack MCP tools (`slack_read_thread` / `slack_read_channel`). Parse the channel id and the `p<ts>` into a timestamp (`p1780411379622949` → `1780411379.622949`).
- **Public web** (handbook, blog, docs): `WebFetch`.
- **Access-gated sources** (Google Docs, Notion, internal tools without an MCP reader): these usually can't be fetched. Ask the user to paste the relevant section or export it. Do not guess the contents.

**2b. Infrastructure & platform work.** Label-mined issues skew toward user-facing features. Platform migrations, performance/scaling work, and tech debt are routinely untracked or unlabeled, so they vanish from a backlog-only plan. Prompt explicitly:

> Separately — what infrastructure, platform, or tech-debt work needs a place in this quarter? Migrations, rewrites, scaling/performance, reliability, cost. These often have no issue (e.g. "port HyperCache to Rust"), so name them even if there's nothing to link. (Reply "none" if it's all captured above.)

Capture each as a named initiative with a one-line rationale, even when it has no issue or doc. These become a first-class infrastructure theme in Step 4, not an afterthought.

Distill every source and initiative into a few bullet points (direction, commitments, named bets, constraints) and keep them; these feed theme weighting (Step 4), the reflection (Step 5), and the HOGS seeds (Step 6). If a link can't be reached, say so explicitly and ask the user to paste it rather than proceeding as if you read it.

### Step 3: Mine Open Issues

```bash
~/.claude/skills/quarterly-planning/scripts/fetch-issues.sh
```

This writes label coverage to stderr and a de-duplicated JSON array to stdout, sorted by engagement (`reactions + comments`). Each issue has: `number`, `title`, `url`, `labels`, `comments`, `reactions`, `createdAt`, `updatedAt`, `milestone`, `assignees`, `author`.

Capture stdout to a file so you can re-read it without re-querying:

```bash
~/.claude/skills/quarterly-planning/scripts/fetch-issues.sh > /tmp/qplan-issues.json 2>/tmp/qplan-coverage.txt
cat /tmp/qplan-coverage.txt
```

**Surface the coverage report to the user**, including any label reported as `not found` — that label contributed nothing and the user may want to correct it or drop it from `QPLAN_LABELS`.

### Step 4: Cluster Issues into Themes

Read `/tmp/qplan-issues.json` and group every issue into a small number of coherent themes (aim for 4-8). Use the `feature/*` labels as natural seeds, then refine by title semantics so related work lands together regardless of label. Engagement (`reactions + comments`) is a demand signal, not the only one; long-open high-engagement issues are strong theme anchors. Weight themes that the Step 2 supporting documents call out as priorities — a strategy doc or RFC naming a direction elevates the matching theme even if its issue count is modest.

**Always reserve an infrastructure / platform theme**, seeded from the Step 2b initiatives plus any infra issues (these often carry `performance` or no `feature/*` label, so they cluster poorly on labels alone — fold them in by title). Feature demand is loud and infra is quiet; if you let issue counts drive the map, platform work disappears. Surface it as its own theme even when it's mostly un-issued initiatives, and label those entries clearly (e.g. `(no issue — from planning)`).

For each theme, present:

- **Theme name** — short and concrete.
- **Issue count** and a one-line description of what ties them together.
- **Top issues** by engagement: `#number [Nr Nc] title` with the URL.
- **Signal** — one line on why this theme matters (demand, age, strategic fit).

Present the full theme map, then ask:

> Here are the themes I extracted from {N} open issues. Before we turn these into goals:
>
> 1. Do these groupings look right? Anything to split, merge, or rename?
> 2. Any theme that's noise we should set aside?

If the `themes` argument was passed, stop here.

### Step 5: Reflect on Last Quarter

Fetch last quarter's goals for context:

```bash
source ~/.claude/skills/quarterly-planning/scripts/config.sh
echo "$QPLAN_GOALS_URL"
```

Try `WebFetch` on `$QPLAN_GOALS_URL` first. The posthog.com team page is client-rendered and often returns 404 to WebFetch; if it fails, **ask the user to paste last quarter's goals** (or point you at a saved copy). Do not guess them.

With last quarter's goals in hand, do the handbook's "Last Quarter Reflection": for each prior objective, note whether it landed, slipped, or was abandoned, and surface any unexpected wins. Cross-reference the themes from Step 4 — a slipped objective whose theme is still hot is a strong carry-forward candidate.

### Step 6: HOGS Framework

Walk the user through HOGS, seeding each prompt with what the themes already suggest so the user reacts rather than starts from blank:

> Let's run HOGS to shape the goals. I'll seed each with what the backlog hints at — add, correct, or veto:
>
> - **Hope** — what are you excited to explore or build? _(seeds: …)_
> - **Obstruction** — what gaps or blockers stop the team shipping 2x more? _(seeds: …)_
> - **Growth** — highest-impact initiatives, recurring user requests, the 1-year vision? _(seeds: …)_
> - **Sneak Attack** — competitive threats or overlooked topics? _(seeds: …)_

Wait for the user's input. Pull the themes, supporting documents, and reflection forward as candidate seeds for each bucket.

### Step 7: Draft the Quarter Goals

Synthesize the supporting documents, themes, reflection, and HOGS into **2-4 objectives** (fewer is better). Map each objective back to the themes and representative issues it absorbs, so the backlog connection is visible. Honor the format and principles in **PostHog's Goal Format** above.

**Account for the infrastructure theme explicitly.** Before finalizing, confirm the Step 2b / Step 4 infrastructure work is either inside an objective or consciously deferred — never silently dropped. Infra that underpins a feature objective (e.g. a read-store or cache migration enabling real-time evaluation) belongs in that objective's "What we'll ship" with its own owner, so it's resourced rather than assumed. If you defer infra, say so in the leftover-themes note.

Output the draft as raw markdown inside a code block so the user can copy it into a posthog.com goals PR:

````markdown
```markdown
# {QPLAN_TEAM_NAME} — {Quarter} Goals

## Objective 1: {clear, ambitious statement}

**Rationale:** {why this matters now}

**What we'll ship:**
- {deliverable} — @{owner}
- {deliverable} — @{owner}

**Success metric:** {the outcome that signals done}

_Backlog: #{issue}, #{issue} (theme: {theme name})_

## Objective 2: …
```
````

After the draft, note any major themes you deliberately left out of the objectives and why (PostHog favors few objectives; explicitly parking a theme is a feature, not an omission).

### Step 8: Offer to Save

Ask whether to save the draft:

> Want me to save this draft to your notes? I'll write it to `~/dev/haacked/notes/PostHog/quarterly-planning/{quarter}-{team-slug}.md`.

If the user confirms, write the markdown there (create the directory if needed). Do not open a PR or post anything publicly without an explicit, separate request — goal PRs are reviewed in an all-hands and are the user's to author.

## Notes

- **Issues, not the project board.** This skill plans _new_ objectives from the issue backlog. For tracking in-flight sprint work, use `/sprint-planning` instead.
- **Labels are configurable and fault-tolerant.** A label that doesn't exist is reported and skipped, never fatal. If `feature/feature-management` (or any label) reports `not found`, surface it — the label may have been renamed or may not exist yet.
- **Never invent last quarter's goals.** If the page won't load, ask.
