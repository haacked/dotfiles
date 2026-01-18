# Support Investigation

Start a deterministic support investigation workflow with automatic note organization.

## Arguments (parsed from user input)

- `find` - Find existing support notes without starting a new investigation
  - `find zendesk <number>` - Find notes for a Zendesk ticket (e.g., `find zendesk 40875`)
  - `find github <number>` - Find notes for a GitHub issue (e.g., `find github 12345`)
  - `find z <number>` - Shorthand for Zendesk (e.g., `find z 40875`)
  - `find gh <number>` - Shorthand for GitHub (e.g., `find gh 12345`)
- **ticket_type**: `zendesk` or `github` (required for new investigations)
- **ticket_number**: The ticket/issue number (required)

Example invocations:

**Find existing notes:**

- `/support find zendesk 40875` - Find existing notes for Zendesk ticket
- `/support find gh 12345` - Find existing notes for GitHub issue

**Start new investigation:**

- `/support zendesk 40875`
- `/support github 12345`
- `/support z 40875` (shorthand)
- `/support gh 12345` (shorthand)

## Your Task

### Step 1: Parse and Validate Arguments

Extract from user input:

- `find_mode` = true if first argument is "find"
- `ticket_type` = zendesk (or z) / github (or gh)
- `ticket_number` = numeric ticket ID

Normalize shorthands:

- `z` → `zendesk`
- `gh` → `github`

If either ticket_type or ticket_number is missing, ask the user for them. Do not proceed without both.

### Step 1.5: Handle Find Mode

If `find_mode` is true, use the helper script to search for existing notes:

```bash
result=$(~/.dotfiles/ai/bin/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)
```

**Present results based on status:**

If `status` is "found":

- Display: "Found existing support notes for {ticket_type} #{ticket_number}"
- Show the directory path: `$notes_dir`
- Show the notes file path: `$notes_dir/notes.md`
- Read and show a summary of the notes file (first ~30 lines)
- Offer to open or continue the investigation

If `status` is "new":

- Display: "No existing notes found for {ticket_type} #{ticket_number}"
- Show where notes would be created: `$notes_dir`
- Suggest running `/support {ticket_type} {ticket_number}` (without `find`) to start a new investigation

**Then stop** - do not proceed with creating directories or files in find mode.

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
