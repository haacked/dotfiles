---
name: support
description: Start a support investigation workflow with automatic note organization
argument-hint: [find|zendesk|github] <number>
disable-model-invocation: true
---

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

### Step 2: Locate the Notes Directory

Run the helper script to find an existing ticket or get the path for a new one. Never construct paths manually — the script handles week calculations, backwards search through previous weeks, and directory validation.

```bash
result=$(~/.claude/skills/support/scripts/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)
```

**If `find_mode` is true**, present results and stop — do not create any directories or files:

- `status` is "found": Display "Found existing support notes for {ticket_type} #{ticket_number}", show the directory and `$notes_dir/notes.md` paths, read and summarize the first ~30 lines of the notes file, and offer to continue the investigation.
- `status` is "new": Display "No existing notes found for {ticket_type} #{ticket_number}", show where notes would be created, and suggest running `/support {ticket_type} {ticket_number}` to start a new investigation.

**If `find_mode` is false**, create the directory if needed and proceed:

```bash
if [[ "$status" == "found" ]]; then
    echo "Found existing ticket at: $notes_dir"
else
    echo "Creating new ticket at: $notes_dir"
    mkdir -p "$notes_dir"
fi
```

### Step 3: Initialize and Confirm

Create `notes.md` in `$notes_dir` using the template from `templates/investigation-notes.md`. Construct the ticket URL as:

- Zendesk: `https://posthoghelp.zendesk.com/agent/tickets/{number}`
- GitHub: `https://github.com/PostHog/posthog/issues/{number}`

Tell the user:

1. Where notes are being stored (full path)
2. The ticket URL for reference
3. Ask them to describe the customer's issue

Then continue the investigation using the support agent guidelines (systematic debugging, documentation, etc.).

## Boundary: /support vs note-taker

| Use `/support` for | Use `note-taker` for |
| --- | --- |
| Customer tickets (Zendesk, GitHub) | Technical discoveries for future dev |
| Weekly support log summaries | System behavior documentation |
| Time-bounded support work | Knowledge persisting beyond ticket |
| Customer-specific investigation | Cross-cutting insights from multiple cases |

If you discover something during support that should be permanent technical docs, spawn `note-taker` separately to capture it in `~/dev/ai/notes/`.
