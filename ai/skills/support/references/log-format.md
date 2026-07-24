# Weekly Highlights Log Format

The user pastes the log into Slack, so links use Slack link syntax `<URL|name>`. The skeleton lives in `templates/weekly-log.txt`:

```text
Highlights for MM/DD/YY - MM/DD/YY

<TICKET_URL|Customer Name>: <one-paragraph summary>. (Status)

<TICKET_URL|Next Customer>: …
```

## Format rules

- **Heading date range is Mon–Fri only.** Use the `monday` and `friday` from the week-resolution step, formatted `MM/DD/YY - MM/DD/YY`. The support hero rotation runs Mon–Fri; weekend dates don't belong here.
- **Customer name** wraps in Slack link syntax: `<URL|Name>`. URL is the ticket URL or Slack thread URL.
- **GitHub issue links filed this week** go inline as raw URLs (not Slack-linked). Example: `Filed https://github.com/PostHog/posthog/issues/55410 to fix X.`
- **Status** in trailing parens: `(Resolved)`, `(Pending)`, `(Unresolved, Pending)`, `(Pending, To close after deployed)`, `(Closed, no action needed)`. Add a short qualifier when useful.
- **Tone: plain English, very high level.** Two to three short sentences per entry. Sound like a person describing the week to a colleague, not a postmortem.
- **Skip specific numbers unless the number IS the story.** "Each poll bills 10x" matters; "posthog-node/4.11.1 polling from two UK BT IPs" doesn't. Drop SDK version strings, IP addresses, exact event counts, process counts.
- **Skip operational/alert response entries** (e.g., infra alerts you handled) unless the user explicitly asks. Those aren't customer support tickets.
- **Skip already-resolved-prior-to-this-week items** (e.g., SDK bug fixed in a shipped version before the week started) unless they're load-bearing context.
- **Skip code snippets, file paths, ClickHouse queries.** Just the gist.
- **Order entries by ticket number ascending** when both are Zendesk; otherwise group Zendesk first then non-Zendesk (Slack threads, internal escalations).

## Status tag reference

- `(Pending)` — waiting on customer response or follow-up action
- `(Pending, To close after deployed)` — fix submitted, waiting for deployment
- `(Pending, awaiting customer guidance)` — solution proposed, customer needs to choose
- `(Unresolved, Pending)` — still investigating or blocked
- `(Resolved)` — confirmed fixed
- `(Closed, no action needed)` — not a bug, expected behavior explained

## Copying to the clipboard

Ask the user whether to copy to the clipboard. Two options when they say yes:

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
