---
name: vault
description: Operate the notes vault knowledge loop — ingest raw sources (standups, ops reports, meeting transcripts, URLs) into interlinked wiki pages, lint vault health, or show the ingest backlog. Use when the user runs /vault, asks to turn meeting notes or reports into knowledge, or wants a vault health check.
argument-hint: "[ingest [path|url|--tranche N] | lint [area] | status]"
model: sonnet
---

# Vault Operations

The knowledge loop over the PostHog work vault at `~/dev/haacked/notes/PostHog` (paths below are relative to `~/dev/haacked/notes`). The schema (raw vs wiki vs working docs, the log rules) lives in `PostHog/CLAUDE.md` — read it before any operation. The operations log `PostHog/log.md` is both history and the ingest ledger.

## Modes

Parse the first argument from user input.

| Argument | Mode |
| --- | --- |
| `ingest [path\|url\|--tranche N]` | **ingest** — distill raw sources into wiki pages |
| `lint [area]` | **lint** — vault health check |
| `status` | **status** — backlog and recent activity |

## Ingest mode

One source at a time — stay bounded, stay involved.

1. Resolve the target: an explicit vault-relative path or URL from the argument, else run the helper to pick the oldest unprocessed raw source:

```bash
~/.claude/skills/vault/scripts/vault-next-source.sh
```

It prints the oldest raw file not yet named by an `ingest |` log entry (stderr shows the remaining backlog count). `--tranche N` mode: call with `N` to get the N oldest and process each one fully, with its own log entry, before starting the next.

2. Read the source, then `PostHog/Home.md`, then only the wiki pages the source plausibly touches — index-first navigation, never a bulk scan.
3. Rewrite or create the affected wiki pages, bounded to ~10-15 pages per source. Distill, don't transcribe: capture decisions, facts, and system knowledge, not meeting play-by-play. Add `[[wikilinks]]` in both directions. Update `Home.md` only if a new area appeared. **Never modify the raw source.**
4. Append the ledger entry to `PostHog/log.md` — it MUST contain the source's backtick-wrapped vault-relative path, extension included (that exact token is what marks the source processed):

```markdown
## [YYYY-MM-DD] ingest | <short title>

Source: `2026/07/Feature Flags - Growth Review.md`. Updated: [[page-one]], [[page-two]]. New: [[page-three]].
```

5. Report: source, pages updated/created, anything deliberately skipped.

Sources with nothing durable in them (a standup that's all PR links already tracked elsewhere, a meeting with no decisions) still get their log entry — `Updated: none — no durable knowledge` — so the backlog shrinks honestly.

## Lint mode

Mechanical first, judgment second; scope judgment to `[area]` (a folder like `repositories/posthog` or `reference`) or pick a rotating slice — never the whole vault in one pass.

1. Mechanical checks:

```bash
cd ~/dev/haacked/notes && markdownlint-cli2 "PostHog/**/*.md"
~/.claude/skills/vault/scripts/vault-lint-links.sh
```

The links helper reports dead `[[wikilinks]]` and orphan wiki pages (no inbound links). Also check for loose files in vault roots and empty directories (convention violations per the schema).

2. Judgment checks over the scoped area only: contradictions between wiki pages, stale claims (dated assertions that no longer hold), missing cross-links between obviously related pages.
3. Fix mechanical issues after a y/n confirmation. Report judgment issues as a checklist; offer to capture deferred ones as `/followup` items.
4. Append a `lint |` entry to `PostHog/log.md` summarizing what was checked and fixed.

## Status mode

Report, using one Bash call where possible:

- Ingest backlog: `~/.claude/skills/vault/scripts/vault-next-source.sh all | grep -c .`
- Recent activity: the latest few `## [date]` entries in `PostHog/log.md`
- Open follow-ups: `~/.claude/skills/followup/scripts/followup-open.sh 2>/dev/null | grep -c .` (reports 0 when the followup skill isn't installed)
- Last lint: most recent `lint |` entry in `PostHog/log.md` (or "never")

## Boundary: /vault vs /note vs /followup

| `/vault` | `/note` | `/followup` |
| --- | --- | --- |
| In-vault operations loop (ingest, lint) | Capture from a code-repo session into the vault | Capture a "do this later" item |
| Works the raw → wiki pipeline | Writes one topic note | Writes one checklist line |
