---
name: support
description: Support hero workflow — start a ticket investigation with auto-organized notes, find existing notes, or generate the weekly highlights log
argument-hint: "[find|log|zendesk|github] <number-or-date>"
disable-model-invocation: true
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

If new, create `notes.md` from `templates/investigation-notes.md`. Construct the ticket URL as:

- Zendesk: `https://posthoghelp.zendesk.com/agent/tickets/{number}`
- GitHub: `https://github.com/PostHog/posthog/issues/{number}`

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
- Ticket URL (use the existing `Ticket URL:` field if present, otherwise reconstruct: Zendesk → `https://posthoghelp.zendesk.com/agent/tickets/{number}`, GitHub → `https://github.com/PostHog/posthog/issues/{number}`; for tickets that exist only in Slack, use the Slack thread URL)
- Symptom — what the customer reported
- Root cause in plain English
- What you did (recommendation, fix, handoff)
- Status
- Any GitHub issues *filed during this week*

### Step 3 — Compose the log

Use this exact format. The user pastes this into Slack, so links use Slack syntax `<URL|name>`.

```
Highlights for MM/DD/YY - MM/DD/YY

<TICKET_URL|Customer Name>: <one-paragraph summary>. (Status)

<TICKET_URL|Next Customer>: …
```

### Format rules

- **Heading date range is Mon–Fri only.** Use the `monday` and `friday` from Step 1, formatted `MM/DD/YY - MM/DD/YY`. The support hero rotation runs Mon–Fri; weekend dates don't belong here.
- **Customer name** wraps in Slack link syntax: `<URL|Name>`. URL is the ticket URL or Slack thread URL.
- **GitHub issue links filed this week** go inline as raw URLs (not Slack-linked). Example: `Filed https://github.com/PostHog/posthog/issues/55410 to fix X.`
- **Status** in trailing parens: `(Resolved)`, `(Pending)`, `(Unresolved, Pending)`, `(Pending, To close after deployed)`, `(Closed, no action needed)`. Add a short qualifier when useful.
- **Tone: plain English, very high level.** Two to three short sentences per entry. Sound like a person describing the week to a colleague, not a postmortem.
- **Skip specific numbers unless the number IS the story.** "Each poll bills 10x" matters; "posthog-node/4.11.1 polling from two UK BT IPs" doesn't. Drop SDK version strings, IP addresses, exact event counts, process counts.
- **Skip operational/alert response entries** (e.g., infra alerts you handled) unless the user explicitly asks. Those aren't customer support tickets.
- **Skip already-resolved-prior-to-this-week items** (e.g., SDK bug fixed in a shipped version before the week started) unless they're load-bearing context.
- **Skip code snippets, file paths, ClickHouse queries.** Just the gist.
- **Order entries by ticket number ascending** when both are Zendesk; otherwise group Zendesk first then non-Zendesk (Slack threads, internal escalations).

### Status tag reference

- `(Pending)` — waiting on customer response or follow-up action
- `(Pending, To close after deployed)` — fix submitted, waiting for deployment
- `(Pending, awaiting customer guidance)` — solution proposed, customer needs to choose
- `(Unresolved, Pending)` — still investigating or blocked
- `(Resolved)` — confirmed fixed
- `(Closed, no action needed)` — not a bug, expected behavior explained

### Step 4 — Write and offer to copy

Save the log to `~/dev/ai/support/HIGHLIGHTS-{monday}.md`. Then ask the user whether to copy to the clipboard. Two options when they say yes:

**Plain text (default — for Slack):**

```bash
pbcopy < ~/dev/ai/support/HIGHLIGHTS-{monday}.md
```

The `<URL|name>` syntax renders as clickable links in Slack on paste.

**RTF (for rich-text editors like Notion, email, docs):**

Build a parallel HTML file with proper `<a href>` tags (replacing each `<URL|name>` with `<a href="URL">name</a>` and wrapping each entry in `<p>…</p>`). Then:

```bash
textutil -convert rtf -stdout /tmp/weekly-log.html > /tmp/weekly-log.rtf
osascript <<'EOF'
set rtfData to read (POSIX file "/tmp/weekly-log.rtf") as «class RTF »
set plainText to do shell script "textutil -convert txt -stdout /tmp/weekly-log.html"
set the clipboard to {Unicode text:plainText, «class RTF »:rtfData}
EOF
```

Setting both `Unicode text` and `«class RTF »` is required — RTF-only clipboards don't paste in many apps.

---

## Boundary: /support vs note-taker

| Use `/support` for | Use `note-taker` for |
| --- | --- |
| Customer tickets (Zendesk, GitHub, Slack escalations) | Technical discoveries for future dev |
| Weekly support hero log | System behavior documentation |
| Time-bounded support work | Knowledge persisting beyond a ticket |
| Customer-specific investigation | Cross-cutting insights from multiple cases |

If you discover something during support that should be permanent technical docs, spawn `note-taker` separately to capture it under `~/dev/ai/notes/`.
