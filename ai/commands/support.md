# Support Investigation

Start a deterministic support investigation workflow with automatic note organization.

## Arguments (parsed from user input)

- **ticket_type**: `zendesk` or `github` (required)
- **ticket_number**: The ticket/issue number (required)

Example invocations:

- `/support zendesk 40875`
- `/support github 12345`
- `/support z 40875` (shorthand)
- `/support gh 12345` (shorthand)

## Your Task

### Step 1: Parse and Validate Arguments

Extract from user input:

- `ticket_type` = zendesk (or z) / github (or gh)
- `ticket_number` = numeric ticket ID

If either is missing, ask the user for them. Do not proceed without both.

### Step 2: Find or Create Notes Directory (Deterministic)

**ALWAYS** use the helper script to find existing tickets or get the path for new ones:

```bash
~/.dotfiles/ai/bin/support-find-ticket.sh {ticket_type} {ticket_number}
```

This returns tab-separated output:

- `found\t/path/to/existing/ticket` - Ticket exists from a previous week
- `new\t/path/for/new/ticket` - Ticket doesn't exist; use this path

**Never construct paths manually.** The script handles:

- Searching backwards through weeks to find existing tickets
- Monday date calculation for new tickets
- Directory structure and validation

### Step 3: Create Notes Directory and File

```bash
result=$(~/.dotfiles/ai/bin/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)

if [[ "$status" == "found" ]]; then
    echo "Found existing ticket at: $notes_dir"
else
    echo "Creating new ticket at: $notes_dir"
    mkdir -p "$notes_dir"
fi
```

Create `notes.md` in that directory with this template:

```markdown
# {Ticket Type} #{ticket_number}

**Ticket URL**: {constructed_url}
**Started**: {current_date_time}
**Status**: In Progress

## Customer Context

<!-- Customer name, company, environment details -->

## Problem Summary

<!-- One-paragraph description of the issue -->

## Investigation Log

### {timestamp}

<!-- Add investigation notes here -->

## Root Cause

<!-- Fill in when identified -->

## Resolution

<!-- Fill in when resolved -->

## Follow-up Actions

- [ ] <!-- Any follow-up tasks -->
```

Construct URLs as:

- Zendesk: `https://posthoghelp.zendesk.com/agent/tickets/{number}`
- GitHub: `https://github.com/PostHog/posthog/issues/{number}`

### Step 4: Confirm and Continue

Tell the user:

1. Where notes are being stored (full path)
2. The ticket URL for reference
3. Ask them to describe the customer's issue

Then continue the investigation using the support agent guidelines (systematic debugging, documentation, etc.).

## Determinism Guarantees

This command ensures:

1. **Consistent location**: Script always returns `~/dev/ai/support/{monday}/`
2. **Consistent naming**: Script always returns `{ticket_type}-{ticket_number}/`
3. **No manual date math**: Script handles all week calculations
4. **Validation**: Script validates ticket type and number format
5. **Finds existing tickets**: Searches backwards through weeks to find existing tickets

## Boundary: /support vs note-taker

| Use `/support` for | Use `note-taker` for |
|--------------------|----------------------|
| Customer tickets (Zendesk, GitHub) | Technical discoveries for future dev |
| Weekly support log summaries | System behavior documentation |
| Time-bounded support work | Knowledge persisting beyond ticket |
| Customer-specific investigation | Cross-cutting insights from multiple cases |

If you discover something during support that should be permanent technical docs, spawn `note-taker` separately to capture it in `~/dev/ai/notes/`.
