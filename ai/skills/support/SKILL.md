---
name: support
description: Support hero workflow — start a ticket investigation with auto-organized notes, find existing notes, or generate the weekly highlights log. Only invoke when the user explicitly runs /support or asks to start a support ticket investigation.
argument-hint: "[find|log|zendesk|github] <number-or-date>"
model: sonnet
---

# Support Hero Workflow

Three subcommands:

| Subcommand | Purpose |
| --- | --- |
| `/support {zendesk\|github\|z\|gh} <number>` | Start a new ticket investigation with note scaffolding |
| `/support find {zendesk\|github\|z\|gh} <number>` | Locate existing notes for a ticket without creating anything |
| `/support log [--last\|--current\|YYYY-MM-DD]` | Generate the weekly support hero highlights log |

Shorthands: `z` → `zendesk`, `gh` → `github`.

## Routing

Parse the user's args:

1. If the first token is `find`, route to **Find Mode** below.
2. If the first token is `log`, route to **Log Mode** below.
3. Otherwise, route to **Investigation Mode** (the default — start or resume a ticket).

If required arguments are missing for the chosen mode, ask the user before proceeding.

## Ticket URLs

- Zendesk: `https://posthoghelp.zendesk.com/agent/tickets/{number}`
- GitHub: `https://github.com/PostHog/posthog/issues/{number}`
- Tickets that exist only in Slack: use the Slack thread URL

---

## Investigation Mode

Used to start a new investigation or resume an existing one.

Required args: `ticket_type` (zendesk/github) and `ticket_number`.

### Step 1 — Locate the notes directory

Run the helper. Don't construct paths manually — the script handles week math and backwards search.

```bash
result=$(~/.claude/skills/support/scripts/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)
```

### Step 2 — Create or resume

```bash
if [[ "$status" == "found" ]]; then
    echo "Found existing ticket at: $notes_dir"
else
    echo "Creating new ticket at: $notes_dir"
    mkdir -p "$notes_dir"
fi
```

### Step 3 — Initialize and confirm

If new, create `notes.md` from `templates/investigation-notes.md`, constructing the ticket URL per the Ticket URLs section above.

Tell the user where notes live and the ticket URL, then ask them to describe the issue. Continue the investigation using systematic debugging and documentation practices.

---

## Find Mode

Used to locate existing notes without creating anything.

Required args: `ticket_type` and `ticket_number`.

```bash
result=$(~/.claude/skills/support/scripts/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)
```

- `status` = `found`: Show the directory and `$notes_dir/notes.md` paths. Read and summarize the first ~30 lines. Offer to continue the investigation.
- `status` = `new`: Tell the user nothing exists yet, show where it would be created, suggest `/support {ticket_type} {ticket_number}` to start.

**Do not create directories or files in Find Mode.**

---

## Log Mode

Used to generate the weekly support hero highlights log.

Optional arg: `--last` (default), `--current`, or an explicit Monday `YYYY-MM-DD`.

### Step 1 — Resolve the target week

```bash
result=$(~/.claude/skills/support/scripts/support-log-week.sh "${arg:-}")
monday=$(echo "$result" | cut -f1)
friday=$(echo "$result" | cut -f2)
week_dir=$(echo "$result" | cut -f3)
```

The script outputs Monday, Friday, and the directory path tab-separated. Default with no arg is `--last` (the most recently completed Mon–Fri).

### Step 2 — Read all notes for the week

The week directory contains one subdirectory per ticket investigation, plus occasionally loose `.md` files. Read every `notes.md` (or top-level `summary.md` / `<ticket>.md` file). Pull from each:

- Customer or company name
- Ticket URL (use the existing `Ticket URL:` field if present, otherwise reconstruct per the Ticket URLs section above)
- Symptom — what the customer reported
- Root cause in plain English
- What you did (recommendation, fix, handoff)
- Status
- Any GitHub issues *filed during this week*

### Step 3 — Compose the log

Read `~/.claude/skills/support/references/log-format.md` and compose the log following its skeleton, format rules, and status tags.

### Step 4 — Write and offer to copy

Save the log to `~/dev/ai/support/HIGHLIGHTS-{monday}.md`. Then offer to copy it to the clipboard using the plain-text or RTF procedure in the format reference.

---

## Boundary: /support vs note-taker

| Use `/support` for | Use `note-taker` for |
| --- | --- |
| Customer tickets (Zendesk, GitHub, Slack escalations) | Technical discoveries for future dev |
| Weekly support hero log | System behavior documentation |
| Time-bounded support work | Knowledge persisting beyond a ticket |
| Customer-specific investigation | Cross-cutting insights from multiple cases |

If you discover something during support that should be permanent technical docs, spawn `note-taker` separately to capture it in the notes vault (`~/dev/haacked/notes/Dev/repositories/` or `~/dev/haacked/notes/PostHog/repositories/`).
