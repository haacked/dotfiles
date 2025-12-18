# Triage Issues for Feature Flags Team

Identify unlabeled GitHub issues in PostHog/posthog that may belong to the Feature Flags team.

## Your Task

1. **Fetch unlabeled issues** from the last $DAYS days (default: 14) using `gh`:

```bash
gh issue list --repo PostHog/posthog --state open --limit $LIMIT --json number,title,body,labels,createdAt,url --search "created:>=$(date -v-${DAYS:-14}d +%Y-%m-%d) -label:team/feature-flags -label:feature/feature-flags -label:feature/cohorts -label:feature/early-access"
```

2. **Analyze each issue** to determine if it relates to the Feature Flags team's domain:

The Feature Flags team owns:
- **Feature flags**: boolean flags, multivariate flags, percentage rollouts, flag targeting rules
- **Cohorts**: user segments for targeting, dynamic/static cohorts
- **Early access**: early access feature management
- **SDK flag evaluation**: as it relates to feature flag behavior

3. **Present candidates** with your analysis:
   - Issue number and title
   - Suggested labels (from the available labels below)
   - Your confidence level (high/medium/low)
   - Brief reasoning

4. **Ask which issues to label** - let the user select by number or say "all"

5. **Apply labels** using `gh issue edit --repo PostHog/posthog ISSUE_NUMBER --add-label "label-name"`

## Available Labels

- `team/feature-flags` - Ownership label for the feature flags team
- `feature/feature-flags` - Issues specifically about feature flags
- `feature/cohorts` - Issues specifically about cohorts/user segments
- `feature/early-access` - Issues about early access feature management

## Guidelines

- Be conservative - only suggest labels when reasonably confident
- An issue can have multiple feature labels but typically only one team label
- If an issue mentions feature flags in passing but is really about something else (e.g., billing, UI bugs unrelated to flags), skip it
- Look for keywords like: feature flag, cohort, rollout, targeting, early access, beta

## Arguments

- `$DAYS` - Look back this many days (default: 14)
- `$LIMIT` - Maximum issues to fetch (default: 30)
