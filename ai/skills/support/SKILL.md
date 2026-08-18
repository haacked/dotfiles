---
name: support
description: Support hero workflow — start a ticket investigation with auto-organized notes, find existing notes, or generate the weekly highlights log. Only invoke when the user explicitly runs /support or asks to start a support ticket investigation.
argument-hint: "[find|log|posthog|zendesk|github] <number-or-url-or-date>"
model: sonnet
---

# Support Hero Workflow

Three subcommands:

| Subcommand | Purpose |
| --- | --- |
| `/support {posthog\|zendesk\|github\|ph\|z\|gh} <number>` | Start a new ticket investigation with note scaffolding |
| `/support <ticket-url>` | Same, reading the type and number from a pasted ticket URL |
| `/support find {posthog\|zendesk\|github\|ph\|z\|gh} <number>` | Locate existing notes for a ticket without creating anything |
| `/support find <ticket-url>` | Same, from a pasted ticket URL |
| `/support log [--last\|--current\|YYYY-MM-DD]` | Generate the weekly support hero highlights log |

Shorthands: `ph` → `posthog`, `z` → `zendesk`, `gh` → `github`.

`posthog` means an in-app support ticket. The in-app inbox is PostHog's own support product, and it replaces Zendesk; tickets carried over from Zendesk keep their old number as a tag (see Migrated Tickets).

## Routing

Parse the user's args:

1. If the first token is `find`, route to **Find Mode** below.
2. If the first token is `log`, route to **Log Mode** below.
3. Otherwise, route to **Investigation Mode** (the default — start or resume a ticket).

Expand the shorthands before calling the scripts: `ph` → `posthog`, `z` → `zendesk`, `gh` → `github`. A pasted ticket URL needs no expansion; hand it to the scripts as a single quoted argument and they work out the type and number themselves.

If required arguments are missing for the chosen mode, ask the user before proceeding.

## Ticket URLs

- PostHog in-app: `https://us.posthog.com/project/2/support/tickets/{number}`
- Zendesk: `https://posthoghelp.zendesk.com/agent/tickets/{number}`
- GitHub: `https://github.com/PostHog/posthog/issues/{number}`
- Tickets that exist only in Slack: use the Slack thread URL

The in-app team id is always `2`, PostHog's own internal project, whichever customer the ticket concerns. Never substitute the customer's project id.

### Migrated Tickets

A ticket carried over from Zendesk keeps a `zendesk/{number}` tag. Its notes live under `posthog-{in_app_number}`, and the front matter records the old number as `**Linked Zendesk**: zendesk/{number}`. That line is how `/support find zendesk {number}` reaches the notes afterwards, so always write it when the tag is present. Without it, an old Zendesk number scaffolds a duplicate investigation.

---

## Investigation Mode

Used to start a new investigation or resume an existing one.

Required args: `ticket_type` (posthog/zendesk/github) and `ticket_number`, or a single ticket URL.

### Step 1 — Locate the notes directory

Run the helper. Don't construct paths manually — the script searches every week on record and works out where a new ticket belongs.

```bash
result=$(~/.claude/skills/support/scripts/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)
```

### Step 2 — Read the ticket

For a `posthog` ticket, pull the ticket and its thread with `posthog-cli api`. Prefer this over the browser: it returns structured fields (status, priority, assignee, tags, customer name and email, person and session context), it's faster, and it can't touch anything customer-visible.

Read `~/.claude/skills/posthog-context/SKILL.md` first if you haven't this session. It requires `posthog-cli api --agent-help` before your first call, and `info <tool>` before each `call`.

```bash
posthog-cli api call --json conversations-tickets-retrieve '{"id":"{ticket_number}"}'
posthog-cli api call --json conversations-tickets-messages-retrieve '{"id":"{ticket_number}","limit":50}'
```

- The CLI is already scoped to project 2, so pass the bare ticket number as `id`. The ticket's UUID works too.
- `conversations-tickets-list` searches the inbox: `search` matches a ticket number exactly, or a customer name or email; it also filters on `status`, `priority`, `tags`, `assignee`, and `sla`.
- The thread paginates at 50 by default, 200 max. Read `count` and `next` from the envelope and page through long threads. It includes private internal notes, flagged as `is_private`.
- All three tools need the `ticket:read` scope.

**Read-only.** The same tool catalog carries four enabled write tools: `conversations-tickets-reply-create`, `conversations-tickets-update`, `conversations-tickets-notes-partial-update`, and `conversations-tickets-notes-destroy`. Never call them. A reply is customer-visible, and status, assignment, or tag changes move the ticket in someone else's queue.

**Fallback**: if the CLI is unavailable, open the ticket URL with Chrome automation and read the page. Only as a fallback; clicking around the support UI risks triggering something customer-visible.

There's no equivalent CLI path for the other types: use `gh issue view {number} --repo PostHog/posthog --comments` for GitHub, and Chrome automation for Zendesk.

### Step 3 — Create or resume

If the ticket carries a `zendesk/{n}` tag and Step 1 returned `new`, look for pre-migration notes and adopt them instead of creating a second directory:

```bash
if [[ "$status" == "new" ]]; then
    migrated=$(~/.claude/skills/support/scripts/support-find-ticket.sh zendesk {n})
    if [[ "$(echo "$migrated" | cut -f1)" == "found" ]]; then
        status="found"
        notes_dir=$(echo "$migrated" | cut -f2)
    fi
fi

if [[ "$status" == "found" ]]; then
    echo "Found existing ticket at: $notes_dir"
else
    echo "Creating new ticket at: $notes_dir"
    mkdir -p "$notes_dir"
fi
```

### Step 4 — Initialize and confirm

If new, create `notes.md` from `templates/investigation-notes.md`, constructing the ticket URL per the Ticket URLs section above. For a migrated ticket, add the `**Linked Zendesk**: zendesk/{n}` line under the ticket URL; find mode depends on it.

Tell the user where notes live and the ticket URL. For an in-app ticket, summarize what you read in Step 2 instead of asking them to restate it; otherwise ask them to describe the issue. Continue the investigation using systematic debugging and documentation practices.

---

## Find Mode

Used to locate existing notes without creating anything.

Required args: `ticket_type` and `ticket_number`, or a single ticket URL.

```bash
result=$(~/.claude/skills/support/scripts/support-find-ticket.sh {ticket_type} {ticket_number})
status=$(echo "$result" | cut -f1)
notes_dir=$(echo "$result" | cut -f2)
```

- `status` = `found`: Show the directory and `$notes_dir/notes.md` paths. Read and summarize the first ~30 lines. Offer to continue the investigation. A `zendesk` lookup can legitimately land on a `posthog-{number}` directory, which means the ticket was migrated and the notes are already filed under its in-app number.
- `status` = `new`: Tell the user nothing exists yet, show where it would be created, suggest `/support {ticket_type} {ticket_number}` to start.

A `zendesk` number that finds nothing locally may still have been migrated, with no notes taken yet. `posthog-cli api call --json conversations-tickets-list '{"tags":"[\"zendesk/{number}\"]"}'` resolves whether it was, and gives its in-app number to investigate under.

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
| Customer tickets (in-app, Zendesk, GitHub, Slack escalations) | Technical discoveries for future dev |
| Weekly support hero log | System behavior documentation |
| Time-bounded support work | Knowledge persisting beyond a ticket |
| Customer-specific investigation | Cross-cutting insights from multiple cases |

If you discover something during support that should be permanent technical docs, spawn `note-taker` separately to capture it in the notes vault (`~/dev/haacked/notes/Dev/repositories/` or `~/dev/haacked/notes/PostHog/repositories/`).
