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

### Step 1: Parse and Validate Arguments

Extract from user input:

- `find_mode` = true if first argument is "find"
- `slug` = optional kebab-case note name (e.g., `cohort-uploads`, `oauth-flow`)

### Step 1.5: Handle Find Mode

If `find_mode` is true:

#### Case A: No slug provided (list all notes)

Use the helper script to list all notes for the current repository:

```bash
~/.dotfiles/ai/bin/note-list.sh
```

This returns tab-separated output (one per line):

- `<slug>\t<path>\t<title>`

**Present results:**

If notes exist:

- Display: "Found {count} notes for {org}/{repo}:"
- List each note with its slug and title
- Offer to open or read any of them

If no notes exist:

- Display: "No notes found for {org}/{repo}"
- Suggest running `/note <slug>` to create one

#### Case B: Slug provided (find specific note)

Use the helper script to find the note:

```bash
~/.dotfiles/ai/bin/note-find.sh {slug}
```

This returns tab-separated output:

- `found\t/path/to/note.md` - Note exists
- `new\t/path/where/note/would/be.md` - Note doesn't exist

**Present results based on status:**

If `status` is "found":

- Display: "Found note: {slug}"
- Show the file path
- Read and show a summary of the note (first ~30 lines)
- Offer to open or continue editing

If `status` is "new":

- Display: "No note found for slug: {slug}"
- Show where it would be created
- Suggest running `/note {slug}` (without `find`) to create it

**Then stop** - do not proceed with creating notes in find mode.

### Step 2: Find or Create Note Path (Deterministic)

If `find_mode` is false:

If slug is missing, ask the user what to name the note. Suggest a slug based on recent conversation context.

**ALWAYS** use the helper script to find existing notes or get the path for new ones:

```bash
~/.dotfiles/ai/bin/note-find-or-create.sh {slug}
```

This returns tab-separated output:

- `found\t/path/to/existing/note.md` - Note already exists
- `new\t/path/to/new/note.md` - Note doesn't exist; use this path

**Never construct paths manually.** The script handles:

- Deriving org/repo from the current git repository
- Building the path `~/dev/ai/notes/{org}/{repo}/{slug}.md`
- Validating the slug format

### Step 3: Create or Update Note

```bash
result=$(~/.dotfiles/ai/bin/note-find-or-create.sh {slug})
status=$(echo "$result" | cut -f1)
note_path=$(echo "$result" | cut -f2)

if [[ "$status" == "found" ]]; then
    echo "Found existing note at: $note_path"
else
    echo "Creating new note at: $note_path"
    mkdir -p "$(dirname "$note_path")"
fi
```

**If creating a new note**, use this template (insert today's date in YYYY-MM-DD format):

```markdown
# {Title} Technical Discovery

**Discovery Date**: {today's date in YYYY-MM-DD format}
**Context**: {Brief description of what problem led to this exploration}

## Summary

{2-3 sentence overview of what was discovered and why it matters}

## Problem Context

- **Original Issue**: {What you were trying to solve}
- **Why This Was Complex**: {What made this non-obvious}

## System Overview

{High-level architecture and data flow}

## Key Components

### {Component Name}

- **Location**: {File path}
- **Responsibility**: {What this component does}
- **Gotchas**: {Non-obvious behaviors}

## Code Examples

```{language}
// Context: {When/why you'd use this}
```

## Common Pitfalls

1. **{Issue}**: {Description}
   - **Symptom**: {How this manifests}
   - **Solution**: {How to handle}

## Related Resources

- {Links to files, PRs, issues, documentation}
```

**If updating an existing note**, read the current content and add new discoveries while preserving existing knowledge.

### Step 4: Confirm and Gather Context

Tell the user:

1. Where the note is being stored (full path)
2. Whether this is a new note or updating an existing one
3. Ask them to describe what they discovered (if not already clear from conversation)

Then create or update the note based on:

- The current conversation context
- Any code explored during this session
- Debugging insights or system behaviors discovered

## Quality Standards

Your notes should:

- **Eliminate re-discovery**: Provide enough detail that the same exploration isn't needed again
- **Enable quick context**: Allow someone to understand the system in minutes, not hours
- **Support implementation**: Include practical examples and configuration details
- **Reference authority**: Link to specific files, commits, or PRs

## Determinism Guarantees

This command ensures:

1. **Consistent location**: Script derives org/repo from git automatically
   - PostHog repos: `~/dev/haacked/notes/PostHog/repositories/{repo}/{slug}.md`
   - Other repos: `~/dev/ai/notes/{org}/{repo}/{slug}.md`
2. **Consistent naming**: Kebab-case slugs enforced by script
3. **No manual path construction**: Script handles all path building
4. **Validation**: Script validates slug format and git context

## Boundary: /note vs /support

| Use `/note` for | Use `/support` for |
|-----------------|-------------------|
| Technical discoveries for future dev | Customer tickets (Zendesk, GitHub) |
| System behavior documentation | Weekly support log summaries |
| Knowledge that persists indefinitely | Time-bounded support work |
| Cross-cutting insights | Customer-specific investigation |

If you discover something during support that should be permanent technical docs, use `/note` to capture it separately.

## Script Reference

| Script | Purpose |
|--------|---------|
| `note-find.sh <slug>` | Find a specific note by slug |
| `note-list.sh` | List all notes for current repo |
| `note-find-or-create.sh <slug>` | Used for creation workflow (find or get new path) |
