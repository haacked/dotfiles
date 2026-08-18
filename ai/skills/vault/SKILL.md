---
name: vault
description: Operate the notes vault knowledge loop — ingest raw sources (standups, ops reports, meeting transcripts, URLs) into interlinked wiki pages, lint vault health, consolidate duplicate wiki pages, or show the ingest backlog. Use when the user runs /vault, asks to turn meeting notes or reports into knowledge, wants duplicate notes merged, or wants a vault health check.
argument-hint: "[ingest [path|url|--tranche N] | lint [area] | consolidate [area|pages] | status]"
model: sonnet
---

# Vault Operations

The knowledge loop over the PostHog work vault at `~/dev/haacked/notes/PostHog` (paths below are relative to `~/dev/haacked/notes`). The schema (raw vs wiki vs working docs, the log rules) lives in `PostHog/CLAUDE.md` — read it before any operation. The operations log `PostHog/log.md` is both history and the ingest ledger: a backtick-wrapped vault-relative path anywhere in the log marks that raw source as ingested, so only ingest entries may backtick-wrap paths — every other entry type writes paths plain or as `[[wikilinks]]`. Ledger entries dated before 2026-08-18 name raw paths without the `raw/` prefix (pre-move layout); both forms mark a source ingested.

## Modes

Parse the first argument from user input.

| Argument | Mode |
| --- | --- |
| `ingest [path\|url\|--tranche N]` | **ingest** — distill raw sources into wiki pages |
| `lint [area]` | **lint** — vault health check |
| `consolidate [area\|pages]` | **consolidate** — merge duplicate or overlapping wiki pages |
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
4. Append the ledger entry to `PostHog/log.md` — it MUST contain the source's backtick-wrapped vault-relative path, extension included (that exact token, inside an `ingest |` entry, is what marks the source processed):

```markdown
## [YYYY-MM-DD] ingest | <short title>

Source: `raw/2026/07/Feature Flags - Growth Review.md`. Updated: [[page-one]], [[page-two]]. New: [[page-three]].
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

The links helper reports dead `[[wikilinks]]`, orphan wiki pages (no inbound links), and duplicate wiki page names (consolidation candidates — route to `/vault consolidate`, not lint fixes). Also check for loose files in vault roots and empty directories (convention violations per the schema).

2. Judgment checks over the scoped area only: contradictions between wiki pages, stale claims (dated assertions that no longer hold), missing cross-links between obviously related pages, duplicate or overlapping pages (same topic under different names — route to `/vault consolidate`).
3. Fix mechanical issues after a y/n confirmation — except dead links sourced from raw files, which are permanent (raw is never edited; consolidated-away targets are the common case): report, don't fix. Report judgment issues as a checklist; offer to capture deferred ones as `/followup` items.
4. Append a `lint |` entry to `PostHog/log.md` summarizing what was checked and fixed.

The daily ingest drip (`bin/vault-ingest-run`) already runs the links helper with `--skip-raw-sources` and files a `lint |` entry when a wiki page's link breaks, staying silent while the findings match the last report. Orphans, duplicates, markdownlint, and every judgment check belong to this mode.

## Consolidate mode

Merge duplicate or overlapping wiki pages — one survivor absorbs the rest. Wiki layer only: never raw sources, `plans/`, `archive/`, or structural files (`Home.md`, `log.md`, `CLAUDE.md`, `Followups.md`). Interactive only — per-merge confirmation is the point; never run unattended.

1. Gather candidates: explicit pages in the argument form one cluster (a single page means: find and merge that page's duplicates); otherwise run the links helper (above) and take its "Duplicate wiki page names" clusters. When `[area]` is given, keep the clusters that touch it (clusters span directories by nature — never drop a cluster's out-of-area members) and add overlaps noticed while reading the area via `Home.md`. Cap a run at ~5 merges — stay bounded, stay involved.
2. Read every page in a cluster fully. Same name but genuinely different topics is a rename, not a merge — offer to rename the less canonical page and update its inbound links instead.
3. Pick the survivor: most inbound links, then the name that fits conventions (kebab-case in `repositories/`, Title Case elsewhere), then the most complete content.
4. Propose the merge and wait for y/n before writing anything: survivor, pages to absorb, count of inbound links to rewrite, and any links from raw sources that will keep pointing at the old name.
5. On yes: rewrite the survivor as one distilled page — every durable fact from all pages, union of outbound `[[wikilinks]]` minus links between the merged pages (they'd become self-links), no concatenated sections. Rewrite each inbound link to the survivor — grep for the old basename inside `[[ ]]` to catch `[[name]]`, `[[name|alias]]`, `[[name#heading]]`, and `[[dir/name]]` forms; preserve aliases, and re-anchor or drop `#heading` fragments that don't exist on the survivor. Update links in every editable file — wiki pages, `Home.md`, `Followups.md`, and working docs under `plans/` or `archive/` — but never `log.md` or raw sources. Re-grep the old basename before deleting: remaining `[[ ]]` hits must be only raw sources, `log.md`, or quoted examples inside code fences. Then delete the absorbed pages with `rm` — the notes auto-backup agent owns git; never commit or push.
6. Append one `consolidate |` entry to `PostHog/log.md` for the run — survivor as a `[[wikilink]]`, absorbed pages as plain paths, renames from step 2 logged the same way (old path → `[[new-name]]`). Never backtick-wrap a path here — per the ledger rule above, that would mark a raw source ingested:

```markdown
## [YYYY-MM-DD] consolidate | <short title>

Merged reference/Feature Flags.md into [[feature-flags]]; rewrote 6 inbound links. Scope: reference.
```

7. Report: merges done, merges skipped and why, any raw-source links left pointing at deleted names.

## Status mode

Report, using one Bash call where possible:

- Ingest backlog: `~/.claude/skills/vault/scripts/vault-next-source.sh all | grep -c .`
- Recent activity: the latest few `## [date]` entries in `PostHog/log.md`
- Open follow-ups: `~/.claude/skills/followup/scripts/followup-open.sh 2>/dev/null | grep -c .` (reports 0 when the followup skill isn't installed)
- Last lint: most recent `lint |` entry in `PostHog/log.md` (or "never")

## Boundary: /vault vs /note vs /followup

| `/vault` | `/note` | `/followup` |
| --- | --- | --- |
| In-vault operations loop (ingest, lint, consolidate) | Capture from a code-repo session into the vault | Capture a "do this later" item |
| Works the raw → wiki pipeline | Writes one topic note | Writes one checklist line |
