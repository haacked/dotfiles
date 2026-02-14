---
name: postmortem
description: Write incident postmortems using the DERP model (Detection, Escalation, Recovery, Prevention). Integrates with incident.io.
argument-hint: [find|list|from <path>|<incident-id-or-slug>]
---

# Postmortem Skill

Write structured incident postmortems using the DERP model.

## Arguments

Parse the argument to determine the mode:

| Argument | Mode | Action |
|----------|------|--------|
| (none) | Interactive | Ask for incident details, then create/continue |
| `find` or `list` | List | Run `postmortem-list.sh` and display results |
| `find <slug>` | Find | Run `postmortem-find.sh <slug>` |
| `from <path>` | Generate from notes | Read notes file and generate postmortem |
| `<incident-id-or-slug>` | Create/Continue | Run `postmortem-find-or-create.sh` |

## Scripts

All scripts are in: `~/.dotfiles/ai/skills/postmortem/scripts/`

- `postmortem-find-or-create.sh <id-or-slug>` - Find or return path for new postmortem
- `postmortem-find.sh [slug]` - Find specific or list all
- `postmortem-list.sh` - List all postmortems with metadata

Output format is tab-separated for easy parsing.

## Storage

Postmortems are stored at: `~/dev/ai/postmortems/PostHog/{slug}.md`

## Template

Use the template at: `~/.dotfiles/ai/skills/postmortem/templates/derp-postmortem.md`

## Workflow: Create/Continue Mode

1. **Run the find-or-create script** with the incident ID or slug
2. **If status is "found"**:
   - Read the existing postmortem
   - Show current status and what sections need work
   - Ask what the user wants to focus on
3. **If status is "new"**:
   - Ask for basic incident details:
     - Title (one-line description)
     - Severity (SEV1-4 or Critical/High/Medium/Low)
     - Approximate duration
     - incident.io URL (if available)
   - Create the postmortem from the template
   - Begin the DERP interview

## Workflow: Generate from Notes

When the user provides a path to existing notes (`/postmortem from <path>`):

1. **Read the notes file** at the provided path
2. **Extract incident identifier**:
   - Look for incident.io IDs (INC-123 pattern)
   - Look for explicit incident references
   - If not found, derive a slug from the notes title or ask the user
3. **Map notes content to DERP sections**:

   | Notes Content | Maps To |
   |---------------|---------|
   | Timeline entries with times | Detection timeline, Recovery timeline |
   | "Root cause", "Why did this happen" | Prevention → Root Cause |
   | Actions taken, "We did X" | Recovery → Actions |
   | Team mentions, "@person" | Escalation → Who responded |
   | Alert mentions, monitoring | Detection → How detected |
   | "Action items", "TODO", "Follow-up" | Prevention → Action Items |
   | Impact statements, user counts | Summary → Impact |

4. **Generate draft postmortem**:
   - Run `postmortem-find-or-create.sh` with the identifier
   - Create the postmortem file using the template
   - Fill in all sections that have data from the notes
   - Leave placeholders for missing information
5. **Show the user what was extracted** and what gaps remain
6. **Offer to fill gaps** through the interactive DERP interview

## DERP Interview Process

Guide the user through each section with targeted questions. Only ask about sections that are incomplete.

### Detection Questions

- How was the incident first detected? (alert, customer report, internal testing)
- What time was it detected? What time did it actually start?
- Were there any earlier warning signs we missed?
- What monitoring or alerting improvements would help?

### Escalation Questions

- Who was paged or joined the response?
- How did communication flow? (Slack channel, video call, etc.)
- Was the initial severity assessment accurate?
- What could improve how we escalate incidents?

### Recovery Questions

- Walk me through the steps taken to restore service
- What was the sequence and timing of recovery actions?
- Were there any false starts or rollbacks?
- What manual steps could be automated?

### Prevention Questions

- What was the root cause?
- What contributing factors allowed this to happen?
- What specific action items will prevent recurrence?
- What lessons should the team take away?

## Guiding Principles

1. **Be conversational** - This is a collaborative interview, not a form
2. **Ask one section at a time** - Don't overwhelm with all questions
3. **Capture exact quotes** - Use the user's words when possible
4. **Link to evidence** - Ask for URLs to Slack threads, dashboards, PRs
5. **Track action items** - Each should have owner, priority, and due date
6. **No blame** - Focus on systems and processes, not individuals

## Status Progression

Update the `status` field in frontmatter as the postmortem progresses:

- `draft` - Initial creation, still gathering information
- `in-review` - All sections complete, awaiting team review
- `complete` - Reviewed and finalized

## Output Format

When displaying postmortem status, show:

```
📝 Postmortem: {title}
   Status: {status} | Severity: {severity} | Duration: {duration}
   Path: {path}

   Sections:
   ✅ Summary - Complete
   ⚠️ Detection - Needs timeline details
   ✅ Escalation - Complete
   ⚠️ Recovery - Missing automation opportunities
   ✅ Prevention - Complete (3 action items)
```

## Example Usage

### Interactive Mode

```
User: /postmortem

Claude: I'll help you write an incident postmortem. What incident are we documenting?

Please provide:
- Incident ID or slug (e.g., INC-123 or "api-outage-jan-2024")
- A one-line title
- Severity level
```

### From Notes Mode

```
User: /postmortem from ~/dev/ai/notes/support-investigation-2024-01-15.md

Claude: I'll generate a postmortem from your investigation notes.

[Reads the notes file]

I found the following information in your notes:

**Incident ID:** INC-456 (from notes)
**Suggested title:** "API rate limiting causing 503 errors"

**Extracted content:**
- Detection: Alert triggered at 14:32 UTC
- Timeline: 12 entries spanning 14:32 - 16:45 UTC
- Recovery actions: 4 steps documented
- Root cause: Misconfigured rate limit threshold
- Action items: 2 items found

**Gaps to fill:**
- Escalation: Who responded?
- Detection: Were there earlier signals?
- Prevention: Owner and due dates for action items

Would you like me to create the postmortem and then fill in the gaps?
```

### List Mode

```
User: /postmortem list

Claude: [Runs postmortem-list.sh]

Found 3 postmortems:

| Slug | Title | Status | Date |
|------|-------|--------|------|
| inc-456 | API rate limiting causing 503s | draft | 2024-01-15 |
| inc-423 | Database connection pool exhaustion | complete | 2024-01-10 |
| inc-401 | CDN cache invalidation failure | in-review | 2024-01-05 |
```
