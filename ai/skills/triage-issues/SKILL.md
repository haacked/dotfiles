---
name: triage-issues
description: Identify unlabeled GitHub issues and external PRs that may belong to a specific team, and normalize conventional title scopes to the team's canonical short form
argument-hint: "[days] [limit] [team] [unattended]"
disable-model-invocation: true
model: sonnet
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
gh issue list --repo PostHog/posthog --state open --limit {limit} --json number,title,labels,createdAt,url --search "created:>=$(date -v-{days}d +%Y-%m-%d) {exclusion_labels}"
```

The `{exclusion_labels}` vary by team. For feature-flags:

```text
-label:team/feature-flags -label:feature/feature-flags -label:feature/cohorts -label:feature/early-access
```

**Note:** The `date -v-Nd` syntax is macOS-specific. On Linux, use `date -d "N days ago"`.

### Step 3: Fetch External PRs

Fetch unlabeled open PRs from the same window and keep only external contributions, which otherwise have no team routing and are easy to miss:

```bash
gh search prs --repo PostHog/posthog --state open --limit {limit} --json number,title,labels,url,createdAt,isDraft,author,authorAssociation -- "created:>=$(date -v-{days}d +%Y-%m-%d) {exclusion_labels}"
```

Keep only PRs whose `authorAssociation` is NOT one of `MEMBER`, `OWNER`, `COLLABORATOR`.

The issue and PR list queries are independent; run them in parallel (a single Bash invocation or parallel tool calls).

For the external PRs, fetch the changed file paths and review state and carry both forward (the paths inform the domain analysis; the review state is reported in the digest). Batch all of them into a single Bash invocation, one tool call rather than one per PR:

```bash
for n in {external_pr_numbers}; do
  echo "PR ${n}: $(gh pr view "$n" --repo PostHog/posthog --json files,reviewDecision --jq '{files: [.files[].path], reviewDecision}')"
done
```

**Body fetching:** Issue and PR bodies are not fetched in bulk. After the subagent returns its initial classification (Step 5), fetch bodies individually only for items the subagent flags as needing more context (typically MEDIUM or LOW confidence candidates where the title and labels are ambiguous). Use `gh issue view {number} --repo PostHog/posthog --json body` or `gh pr view {number} --repo PostHog/posthog --json body`, then pass the bodies back to the subagent for a refined classification. Do not fetch bodies for HIGH-confidence candidates or items already skipped.

### Step 3b: Fetch Internal Feature Flags PR Candidates

Internal (org-member) PRs are routed to teams by reviewer assignment, not labels, so a flags-domain internal PR that never gets the team requested as a reviewer (a CODEOWNERS coverage gap, or a footprint too small to trigger assignment) lands on no board and carries no label. This step surfaces those.

This step is **feature-flags only** (the helper and its path net are flags-specific). Skip it for other teams.

Run the helper script, which finds internal non-bot PRs missing a flags team label in the window, fetches their changed files in parallel, and keeps only those touching flags-domain paths (a deliberately broad net — recall here, precision in the subagent):

```bash
triage-flags-pr-candidates --days {days}
```

It prints a JSON array on stdout: `[{ "number", "title", "author", "paths" }]`. The `paths` are the specific flags-domain files each PR touched — carry them forward as the file-path signal for the subagent (do not re-fetch files for these). If it prints `[]`, there are no internal candidates.

### Step 3c: Early Exit

If the issues list, the external PRs list, and the internal PR candidates are all empty (zero items returned), print the "nothing to triage" digest line for the team and date and stop. Do not proceed to Step 4 or spawn the subagent.

### Step 4: Detect Title Scope Renames

Conventional titles use short team scopes. Scan every fetched item (issues and external PRs alike, whether or not they become candidates) for a title whose conventional scope uses the team's long name, and record a rename that swaps in the canonical scope, keeping the prefix and the rest of the title unchanged.

The scope mapping varies by team. For feature-flags: `(feature-flags)` → `(flags)`, matched case-insensitively under any prefix, e.g. `feat(feature-flags): add bootstrap support` → `feat(flags): add bootstrap support`, `Fix(Feature-Flags): …` → `Fix(flags): …`.

Renames are applied in Step 6, not here.

### Step 5: Spawn Team-Specific Subagent

Use the Task tool to spawn the appropriate triage subagent:

- For `feature-flags`: Use subagent `triage-feature-flags`

Pass the fetched issues, external PRs, and internal PR candidates (Step 3b) to the subagent, each marked as such and with file paths where collected. The subagent will:

1. Analyze each item against the team's domain
2. Return candidates with confidence levels and suggested labels

The internal PR candidates are pre-filtered to those touching flags-domain paths, so many are incidental (a chore, dependency bump, or other team's PR that brushes a flags file). Rely on the subagent to reject those — the path match is only a recall net, not a verdict.

### Step 6: Apply Labels and Renames, and Report

Apply labels and title renames using:

```bash
gh issue edit --repo PostHog/posthog {number} --add-label "{labels}"   # issues
gh pr edit {number} --repo PostHog/posthog --add-label "{labels}"      # PRs
gh issue edit --repo PostHog/posthog {number} --title "{new title}"    # renames (issues)
gh pr edit {number} --repo PostHog/posthog --title "{new title}"       # renames (PRs)
```

**Interactive mode** (default): show the user a summary ("Found X issues, Y external PRs, and Z internal PR candidates from the last N days, C candidates for {team} team, M title renames") and the candidate list — number and title (linked), current labels, suggested labels, confidence, brief reasoning — plus the proposed renames (old title → new title). Then ask which to apply: specific numbers, "all", or "none".

**Unattended mode**: do not ask anything.

Labeling, by item type:

- **Issues and external PRs**: apply labels to HIGH-confidence candidates only; never label MEDIUM or LOW.
- **Internal PRs (Step 3b): report only — do not apply any labels yet**, at any confidence. This is intentional while the path-net + subagent precision is validated against real digests. They appear in the digest as would-be candidates; flipping them to auto-label HIGH is a deliberate later change.

Apply all Step 4 renames; the scope match is mechanical and needs no confidence gating. (Title renames are mechanical, so they apply to internal PRs too.) If a label application or rename fails, note it in the digest and continue without retrying. Then emit a Slack-friendly digest as your final output:

1. Header: `{team name} triage — <date>` with counts: issues scanned, external PRs scanned, internal PRs matched, auto-labeled, renamed, needing decision. Add a one-line note that this is a label queue, not project-board membership (the board is reviewer-driven).
2. `External PRs` — every external PR matched to the domain at any confidence: link, title, author, review state (the `reviewDecision` carried from Step 3), labels applied or suggested, confidence. This section comes first; these are the items most often missed.
3. `Internal PRs missing flags label (report only)` — every internal PR the subagent matched to the domain at any confidence: link, title, author, the suggested labels (not applied), confidence, one-line reasoning. Note these are not labeled automatically yet.
4. `Auto-labeled (HIGH)`: item link, title, labels applied (issues and external PRs only).
5. `Renamed titles`: item link, old title → new title.
6. `Needs a human decision (MEDIUM/LOW)`: item link, title, suggested labels, confidence, one-line reasoning.
7. Any errors.

If there are no candidates and no renames, the digest is the single line: `{team name} triage — <date>: nothing to triage.`

## Adding New Teams

To add support for a new team:

1. Create a new agent file: `ai/agents/triage-{team-name}.md`
2. Define the team's domain, owned labels, keywords, and exclusions
3. Add the team's title scope mapping (long name → canonical scope) to Step 4
4. Add the team identifier to the "Supported team identifiers" list above
