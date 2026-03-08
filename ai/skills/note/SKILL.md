---
name: note
description: Capture complex technical discoveries into structured, reusable notes. Use when explaining system behaviors, documenting debugging insights, or preserving knowledge.
argument-hint: [find|<slug>]
---

# Technical Discovery Note

Capture complex technical discoveries into structured, reusable notes.

## Arguments (parsed from user input)

- `find` - Find existing notes without creating new ones
  - `find` (no args) - List all notes for the current repository
  - `find <slug>` - Find a specific note by slug (e.g., `find cohort-uploads`)
- **slug**: kebab-case name for the note (required for creating/updating)

Example invocations:

**Find existing notes:**

- `/note find` - List all notes for current repo
- `/note find cohort-uploads` - Find specific note by slug

**Create or update notes:**

- `/note cohort-uploads`
- `/note oauth-flow`
- `/note feature-flags-evaluation`

## Your Task

### Step 1: Parse Arguments

Extract from user input:

- `find_mode` = true if first argument is "find"
- `slug` = optional kebab-case note name (e.g., `cohort-uploads`, `oauth-flow`)

### Step 2: Route by Mode

#### Find Mode (`find_mode` is true)

**No slug provided — list all notes:**

```bash
~/.claude/skills/note/scripts/note-list.sh
```

Returns tab-separated `<slug>\t<path>\t<title>` (one per line).

If notes exist, display: "Found {count} notes for {org}/{repo}:" followed by slug and title for each, then offer to open or read any of them.

If no notes exist, display: "No notes found for {org}/{repo}" and suggest running `/note <slug>` to create one.

**Slug provided — find specific note:**

```bash
~/.claude/skills/note/scripts/note-find.sh {slug}
```

Returns tab-separated status and path:

- `found\t/path/to/note.md` - Note exists
- `new\t/path/where/note/would/be.md` - Note doesn't exist

If `found`: display "Found note: {slug}", show the file path, read and summarize the first ~30 lines, then offer to open or continue editing.

If `new`: display "No note found for slug: {slug}", show where it would be created, and suggest running `/note {slug}` (without `find`) to create it.

**Then stop** — do not proceed with creating notes in find mode.

#### Create/Update Mode (`find_mode` is false)

If slug is missing, ask the user what to name the note and suggest a slug based on recent conversation context.

Run the helper script to find an existing note or get the path for a new one:

```bash
result=$(~/.claude/skills/note/scripts/note-find-or-create.sh {slug})
status=$(echo "$result" | cut -f1)
note_path=$(echo "$result" | cut -f2)
```

Never construct paths manually — the script derives org/repo from the current git repository, builds the path `~/dev/ai/notes/{org}/{repo}/{slug}.md`, and validates the slug format.

If `status` is `found`: tell the user the existing note path and that you're updating it, then read the current content and add new discoveries while preserving existing knowledge.

If `status` is `new`: tell the user the new note path, create the parent directory (`mkdir -p "$(dirname "$note_path")"`), and use `templates/discovery-note.md` as the starting point (insert today's date in YYYY-MM-DD format).

Then create or update the note based on the current conversation context, any code explored during this session, and debugging insights or system behaviors discovered.

## Quality Standards

Your notes should:

- **Eliminate re-discovery**: Provide enough detail that the same exploration isn't needed again
- **Enable quick context**: Allow someone to understand the system in minutes, not hours
- **Support implementation**: Include practical examples and configuration details
- **Reference authority**: Link to specific files, commits, or PRs

## Boundary: /note vs /support

| Use `/note` for | Use `/support` for |
| --- | --- |
| Technical discoveries for future dev | Customer tickets (Zendesk, GitHub) |
| System behavior documentation | Weekly support log summaries |
| Knowledge that persists indefinitely | Time-bounded support work |
| Cross-cutting insights | Customer-specific investigation |

If you discover something during support that should be permanent technical docs, use `/note` to capture it separately.
