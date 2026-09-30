---
name: triage-issues
description: Identify unlabeled GitHub issues and external PRs that may belong to a specific team, and normalize conventional title scopes to the team's canonical short form. Only invoke when the user explicitly runs /triage-issues or asks to triage the team's GitHub issues.
disable-model-invocation: true
argument-hint: "[days] [team] [unattended]"
model: sonnet
metadata:
  execution-tier: balanced
---

# Triage GitHub Issues and External PRs

Identify unlabeled GitHub issues and external (community) pull requests that may belong to a specific team.

## Arguments (parsed from user input)

- **days**: How many days back to search (default: 14)
- **team**: Which team to triage for (default: feature-flags)
- **unattended**: Run without prompts: auto-apply HIGH-confidence labels and emit a digest instead of asking questions. For scheduled runs.

Example invocations:

- `/triage-issues` → defaults (14 days, feature-flags team)
- `/triage-issues 7` → last 7 days
- `/triage-issues for web-analytics` → triage for web-analytics team
- `/triage-issues last 7 days for product-analytics` → natural language works too
- `/triage-issues 7 unattended` → scheduled mode: auto-label HIGH, output digest

## Your Task

### Step 1: Parse Arguments

Extract from the user's input (or use defaults):

- `days` = number of days to look back (default: 14)
- `team` = team identifier (default: feature-flags)
- `unattended` = present or absent (default: absent)

Supported team identifiers:

- `feature-flags` or `ff` → Feature Flags team
- (future: `web-analytics` or `wa`, `product-analytics` or `pa`, etc.)

If an unsupported team is requested, inform the user which teams are available.

The roster fetch (Step 1b), the issue fetch (Step 2), and the PR helper call (Step 3) do not depend on each other. Run all three as parallel tool calls in one message.

### Step 1b: Fetch the Team Roster

Fetch the GitHub team's member logins once; they drive the draft-PR rule in Steps 3b and 6. For feature-flags the team slug is `team-feature-flags`:

```bash
gh api --paginate orgs/PostHog/teams/team-feature-flags/members --jq '.[].login'
```

Treat these logins (case-insensitive) as the team members. If the roster fetch fails, note it in the digest and fall back to treating every author as a non-team-member (so all draft PRs are skipped rather than mislabeled).

### Step 2: Fetch Issues

Fetch unlabeled issues from PostHog/posthog using `gh`:

```bash
gh issue list --repo PostHog/posthog --state open --limit 1000 --json number,title,labels --search "created:>=$(date -v-{days}d +%Y-%m-%d) {exclusion_labels}" --jq '{fetched: length, issues: [.[] | {number, title, labels: [.labels[].name]}]}'
```

The `{exclusion_labels}` vary by team. For feature-flags:

```text
-label:team/feature-flags -label:feature/feature-flags -label:feature/cohorts -label:feature/early-access-management
```

**Note:** The `date -v-Nd` syntax is macOS-specific. On Linux, use `date -d "N days ago"`.

GitHub search returns at most 1000 results. If `fetched` is 1000, the window holds more unlabeled issues than the fetch returned: report the truncated issue list in the digest's errors section. Link each issue as `https://github.com/PostHog/posthog/issues/{number}`.

### Step 3: Fetch PRs

One helper call returns both PR lists: the external PRs for this step and the internal candidates for Step 3b. The helper is flags-specific, and feature-flags is the only supported team.

```bash
triage-flags-pr-candidates --days {days}
```

The helper searches the window for open PRs that carry none of the feature-flags `{exclusion_labels}`, drops bots, and fetches each remaining PR's changed files. It prints one JSON object on stdout:

```json
{"fetched": 447, "capped": false, "external": [{"number": 123, "title": "…", "author": "…", "labels": ["…"], "reviewDecision": "REVIEW_REQUIRED", "files": ["…"]}], "internal": [{"number": 456, "title": "…", "author": "…", "isDraft": false, "paths": ["…"]}], "unfetched": []}
```

- `external` holds PRs from authors outside the PostHog org. These have no team routing and are easy to miss. The helper drops external drafts, so only non-draft external PRs proceed; drafts wait until they are marked ready for review. Carry `files` forward for the domain analysis and `reviewDecision` for the digest.
- `internal` holds the org members' PRs that Step 3b covers.
- `capped` is true when the search returned GitHub's 1000-result maximum, which means the oldest part of the window went unscanned. Report that in the digest's errors section.
- `unfetched` lists the PRs whose changed files the helper could not fetch. List them in the digest's errors section. An external PR in this list has null `files` and `reviewDecision`, so the subagent classifies it from its title and labels. An internal PR in this list is missing from `internal`.

Link each PR as `https://github.com/PostHog/posthog/pull/{number}`.

**Body fetching:** Issue and PR bodies are not fetched in bulk. After the subagent returns its initial classification (Step 5), fetch bodies individually only for items the subagent flags as needing more context (typically MEDIUM or LOW confidence candidates where the title and labels are ambiguous). Use `gh issue view {number} --repo PostHog/posthog --json body` or `gh pr view {number} --repo PostHog/posthog --json body`, then pass the bodies back to the subagent for a refined classification. Do not fetch bodies for HIGH-confidence candidates or items already skipped.

### Step 3b: Internal Feature Flags PR Candidates

Internal (org-member) PRs are routed to teams by reviewer assignment, not labels, so a flags-domain internal PR that never gets the team requested as a reviewer (a CODEOWNERS coverage gap, or a footprint too small to trigger assignment) lands on no board and carries no label. This step surfaces those.

The helper keeps an internal PR only when its changed files match a flags-domain path pattern. The pattern is broad on purpose, and the subagent rejects PRs that only brush a flags file. Each entry's `paths` lists the flags-domain files the PR touched. Carry `paths` forward as the file-path signal for the subagent, and do not fetch files again for these PRs.

Then drop any candidate that is a draft (`isDraft: true`) and authored by a non-team-member (login not in the Step 1b roster). Keep draft PRs authored by team members (they surface report-only in the digest, never labeled) and all non-draft candidates.

### Step 3c: Early Exit

If the issues list, the external PRs list, and the internal PR candidates are all empty (zero items returned), print the "nothing to triage" digest line for the team and date and stop. Do not proceed to Step 4 or spawn the subagent.

### Step 4: Detect Title Scope Renames

Conventional titles use short team scopes. Scan every fetched item (issues and external PRs alike, whether or not they become candidates) for a title whose conventional scope uses the team's long name, and record a rename that swaps in the canonical scope, keeping the prefix and the rest of the title unchanged.

The scope mapping varies by team. For feature-flags: `(feature-flags)` → `(flags)`, matched case-insensitively under any prefix, e.g. `feat(feature-flags): add bootstrap support` → `feat(flags): add bootstrap support`, `Fix(Feature-Flags): …` → `Fix(flags): …`.

Renames are applied in Step 6, not here.

### Step 5: Spawn Team-Specific Subagent

Use the Agent tool to spawn the appropriate triage subagent:

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

**Interactive mode** (default): show the user a summary ("Found X issues, Y external PRs, and Z internal PR candidates from the last N days, C candidates for {team} team, M title renames, D team-member drafts held") and the candidate list — number and title (linked), current labels, suggested labels, confidence, brief reasoning — plus the proposed renames (old title → new title). Then ask which to apply: specific numbers, "all", or "none".

**Unattended mode**: do not ask anything.

Labeling, by item type:

- **Issues and external PRs**: apply labels to HIGH-confidence candidates only; never label MEDIUM or LOW.
- **Internal PRs (Step 3b)**: apply labels to HIGH-confidence candidates that are ready for review (not draft); never label MEDIUM or LOW, and never label a draft.

Non-team-members' drafts were already dropped in Steps 3 and 3b, so the only drafts that reach this step are team members' own work: report them in the drafts section of the digest so the team sees them in flight, but do not label them. They get labeled on a later run once they are marked ready for review.

Title renames (Step 4) apply in both modes without a separate prompt, since the scope match is mechanical and needs no confidence gating. In interactive mode they are part of what the user approves via "all"; they apply to internal PRs too. Do not rename a PR that was dropped as a non-team-member draft in Steps 3 or 3b: leave WIP from other teams untouched until it is ready. If a label application or rename fails, note it in the digest and continue without retrying. Then emit a Slack-friendly digest as your final output:

1. Header: `{team name} triage — <date>` with counts: issues scanned, external PRs scanned, internal PRs matched, auto-labeled, renamed, needing decision, drafts held. Add a one-line note that this is a label queue, not project-board membership (the board is reviewer-driven).
2. `External PRs` — every non-draft external PR matched to the domain at any confidence: link, title, author, review state (the `reviewDecision` carried from Step 3), labels applied or suggested, confidence. This section comes first; these are the items most often missed.
3. `Auto-labeled (HIGH)`: item link, title, labels applied. Covers issues, external PRs, and ready (non-draft) internal PRs.
4. `Renamed titles`: item link, old title → new title.
5. `Needs a human decision (MEDIUM/LOW)`: item link, title, suggested labels, confidence, one-line reasoning. Covers issues, external PRs, and ready internal PRs.
6. `Team-member drafts (held, not labeled)`: every internal draft PR the subagent matched to the domain: link, title, author, suggested labels (not applied), confidence, one-line reasoning. These get labeled once marked ready for review.
7. Any errors.

If there are no candidates and no renames, the digest is the single line: `{team name} triage — <date>: nothing to triage.`

## Adding New Teams

To add support for a new team:

1. Create a new agent file: `ai/agents/triage-{team-name}.md`
2. Define the team's domain, owned labels, keywords, and exclusions
3. Add the team's title scope mapping (long name → canonical scope) to Step 4
4. Add the team identifier to the "Supported team identifiers" list above
