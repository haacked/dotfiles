---
name: triage-issues
description: Identify unlabeled GitHub issues and external PRs that may belong to a specific team
argument-hint: "[days] [limit] [team] [unattended]"
disable-model-invocation: true
---

# Triage GitHub Issues and External PRs

Identify unlabeled GitHub issues and external (community) pull requests that may belong to a specific team.

## Arguments (parsed from user input)

- **days**: How many days back to search (default: 14)
- **limit**: Maximum items to fetch per type (default: 30)
- **team**: Which team to triage for (default: feature-flags)
- **unattended**: Run without prompts: auto-apply HIGH-confidence labels and emit a digest instead of asking questions. For scheduled runs.

Example invocations:

- `/triage-issues` → defaults (14 days, 30 issues, feature-flags team)
- `/triage-issues 7` → last 7 days
- `/triage-issues 7 50` → last 7 days, up to 50 items per type
- `/triage-issues for web-analytics` → triage for web-analytics team
- `/triage-issues last 7 days for product-analytics` → natural language works too
- `/triage-issues 7 unattended` → scheduled mode: auto-label HIGH, output digest

## Your Task

### Step 1: Parse Arguments

Extract from the user's input (or use defaults):

- `days` = number of days to look back (default: 14)
- `limit` = max items to fetch per type (default: 30)
- `team` = team identifier (default: feature-flags)
- `unattended` = present or absent (default: absent)

Supported team identifiers:

- `feature-flags` or `ff` → Feature Flags team
- (future: `web-analytics` or `wa`, `product-analytics` or `pa`, etc.)

If an unsupported team is requested, inform the user which teams are available.

### Step 2: Fetch Issues

Fetch unlabeled issues from PostHog/posthog using `gh`:

```bash
gh issue list --repo PostHog/posthog --state open --limit {limit} --json number,title,body,labels,createdAt,url --search "created:>=$(date -v-{days}d +%Y-%m-%d) {exclusion_labels}"
```

The `{exclusion_labels}` vary by team. For feature-flags:

```text
-label:team/feature-flags -label:feature/feature-flags -label:feature/cohorts -label:feature/early-access
```

**Note:** The `date -v-Nd` syntax is macOS-specific. On Linux, use `date -d "N days ago"`.

### Step 3: Fetch External PRs

Fetch unlabeled open PRs from the same window and keep only external contributions, which otherwise have no team routing and are easy to miss:

```bash
gh search prs --repo PostHog/posthog --state open --limit {limit} --json number,title,body,labels,url,createdAt,isDraft,authorAssociation -- "created:>=$(date -v-{days}d +%Y-%m-%d) {exclusion_labels}"
```

Keep only PRs whose `authorAssociation` is NOT one of `MEMBER`, `OWNER`, `COLLABORATOR`.

The issue and PR list queries are independent; run them in parallel (a single Bash invocation or parallel tool calls).

For each external PR, fetch the changed file paths and review state in one call and carry both forward (the paths inform the domain analysis; the review state is reported in the digest):

```bash
gh pr view {number} --repo PostHog/posthog --json files,reviewDecision --jq '{files: [.files[].path], reviewDecision}'
```

### Step 4: Spawn Team-Specific Subagent

Use the Task tool to spawn the appropriate triage subagent:

- For `feature-flags`: Use subagent `triage-feature-flags`

Pass the fetched issues and external PRs (marked as such, with file paths where collected) to the subagent for analysis. The subagent will:

1. Analyze each item against the team's domain
2. Return candidates with confidence levels and suggested labels

### Step 5: Apply Labels and Report

Apply labels using:

```bash
gh issue edit --repo PostHog/posthog {number} --add-label "{labels}"   # issues
gh pr edit {number} --repo PostHog/posthog --add-label "{labels}"      # PRs
```

**Interactive mode** (default): show the user a summary ("Found X issues and Y external PRs from the last Z days, N candidates for {team} team") and the candidate list — number and title (linked), current labels, suggested labels, confidence, brief reasoning. Then ask which to label: specific numbers, "all", or "none".

**Unattended mode**: do not ask anything. Apply labels to HIGH-confidence candidates only; never label MEDIUM or LOW. If a label application fails, note it in the digest and continue without retrying. Then emit a Slack-friendly digest as your final output:

1. Header: `{team name} triage — <date>` with counts: issues scanned, external PRs scanned, auto-labeled, needing decision.
2. `External PRs` — every external PR matched to the domain at any confidence: link, title, author, review state (the `reviewDecision` carried from Step 3), labels applied or suggested, confidence. This section comes first; these are the items most often missed.
3. `Auto-labeled (HIGH)`: item link, title, labels applied.
4. `Needs a human decision (MEDIUM/LOW)`: item link, title, suggested labels, confidence, one-line reasoning.
5. Any errors.

If there are no candidates at all, the digest is the single line: `{team name} triage — <date>: nothing to triage.`

## Adding New Teams

To add support for a new team:

1. Create a new agent file: `ai/agents/triage-{team-name}.md`
2. Define the team's domain, owned labels, keywords, and exclusions
3. Add the team identifier to the "Supported team identifiers" list above
