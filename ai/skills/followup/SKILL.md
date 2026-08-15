---
name: followup
description: Capture a follow-up item mid-session in seconds, list open items, close one, or run a review pass. Use when the user says "follow up on this later", "add a followup", "don't let me forget", or runs /followup.
argument-hint: "[list|done <match>|drop <match>|review] <free text>"
model: haiku
---

# Follow-ups

Mid-session capture for things that must not fall through the cracks. Items live in one central file and resurface via the SessionStart hook (`followup-detect.sh`) and `/standup`.

## The file

`~/dev/haacked/notes/PostHog/Followups.md` — `## Open` and `## Archive` sections, newest first, one line per item, never hard-wrapped:

```markdown
- [ ] 2026-08-14 · [PostHog/posthog · haacked/flags-foo] Check p99 after canary rollout ([PR #37211](https://github.com/PostHog/posthog/pull/37211), `rust/feature-flags/src/lib.rs:412`)
```

`- [ ]` open, `- [x]` done, `- [-]` dropped. Closed items carry a `— closed YYYY-MM-DD` or `— dropped YYYY-MM-DD` suffix; the marker is always the final such fragment at the end of the line, since item text may contain its own em dashes. `~/.claude/skills/followup/scripts/followup-open.sh [org/repo]` prints open items — the single owner of the open-item grammar. Non-GitHub contexts use `[no-repo]`.

## Modes

Parse the first argument from user input.

| Argument | Mode |
| --- | --- |
| anything else (default) | **add** — capture the text as a new item |
| `list` | print open items, current repo first |
| `done <match>` | close an item as done |
| `drop <match>` | close an item as dropped |
| `review` | review pass over all open items |

## Add mode (default)

Speed is the point: one script call, at most one Edit, done.

1. Run the helper with the follow-up text:

```bash
~/.claude/skills/followup/scripts/followup-add.sh "<text>"
```

Pass the text as one quoted argument. It inserts the item at the top of `## Open` (creating the file when missing) and prints a capture summary.

2. If the conversation has an obvious source the text doesn't already carry — the PR under discussion, a `file:line` — weave it into the just-added line as a markdown link with one Edit. Skip this when nothing obvious exists; never research to find a link.

3. Relay the script's summary to the user. If the script errors, surface the error — never report a capture that didn't land.

## List mode

Run `followup-open.sh` and print its output grouped: current repo first (derive `org/repo` from `git remote get-url origin`), then the rest, each with its age in days. No file changes.

## Done / drop mode

1. Find open lines matching `<match>` (case-insensitive substring over `followup-open.sh` output).
2. Exactly one match: flip `- [ ]` to `- [x]` (done) or `- [-]` (drop) in place and append ` — closed YYYY-MM-DD` (or ` — dropped YYYY-MM-DD`).
3. Multiple matches: show them numbered and ask which one. Zero: say so and suggest `/followup list`.

Closed items stay under `## Open` until the next `review` sweeps them to `## Archive` — the flip is the fast path.

## Review mode

The deliberate sweep (standup surfacing is the passive one):

1. List every open item with its age; flag items older than 14 days as stale.
2. Ask the user for keep/done/drop decisions in one batch — a compact numbered prompt, not one question per item.
3. Apply the flips, then move all `- [x]` and `- [-]` lines from `## Open` to the top of `## Archive`, preserving their order — directly under the heading and its blank line, creating the blank line (or the section) if missing.
4. Report: kept, done, dropped counts and the oldest remaining item.

## Boundary: /followup vs /handoff vs /note

| `/followup` | `/handoff` | `/note` |
| --- | --- | --- |
| Discrete "do this later" items | Mid-task session bridge | Durable technical knowledge |
| Central checklist, cross-repo | One doc per repo, current task | Slug-named notes per repo |
| Surfaces at session start + standup | Surfaces at session start in that repo | Found when searched |
