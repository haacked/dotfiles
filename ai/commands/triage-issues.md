# Triage GitHub Issues

Identify unlabeled GitHub issues that may belong to a specific team.

## Arguments (parsed from user input)

- **days**: How many days back to search (default: 14)
- **limit**: Maximum issues to fetch (default: 30)
- **team**: Which team to triage for (default: feature-flags)

Example invocations:

- `/triage-issues` → defaults (14 days, 30 issues, feature-flags team)
- `/triage-issues 7` → last 7 days
- `/triage-issues 7 50` → last 7 days, up to 50 issues
- `/triage-issues for web-analytics` → triage for web-analytics team
- `/triage-issues last 7 days for product-analytics` → natural language works too

## Your Task

### Step 1: Parse Arguments

Extract from the user's input (or use defaults):

- `days` = number of days to look back (default: 14)
- `limit` = max issues to fetch (default: 30)
- `team` = team identifier (default: feature-flags)

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

### Step 3: Spawn Team-Specific Subagent

Use the Task tool to spawn the appropriate triage subagent:

- For `feature-flags`: Use subagent `triage-feature-flags`

Pass the fetched issues to the subagent for analysis. The subagent will:

1. Analyze each issue against the team's domain
2. Return candidates with confidence levels and suggested labels

### Step 4: Present Results

Show the user:

1. Summary: "Found X issues from the last Y days, Z candidates for {team} team"
2. List of candidates with:
   - Issue number and title (linked)
   - Current labels
   - Suggested labels
   - Confidence level
   - Brief reasoning

### Step 5: Apply Labels

Ask the user which issues to label:

- They can specify issue numbers: "43654, 43230"
- They can say "all" to label all candidates
- They can say "none" to skip

Apply labels using:

```bash
gh issue edit --repo PostHog/posthog {number} --add-label "{labels}"
```

## Adding New Teams

To add support for a new team:

1. Create a new agent file: `ai/agents/triage-{team-name}.md`
2. Define the team's domain, owned labels, keywords, and exclusions
3. Add the team identifier to the "Supported team identifiers" list above
