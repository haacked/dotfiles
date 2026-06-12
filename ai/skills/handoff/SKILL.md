---
name: handoff
description: Write or resume a handoff document so the next Claude session can pick up the current work. Use when context is filling up, when ending a session mid-task, or at the start of a new session that should continue prior work.
argument-hint: [resume|show|path]
model: sonnet
---

# Session Handoff

Bridge between Claude sessions. Optimized for the next session reading the doc cold, with full tool access but zero conversation history.

## Modes

Parse the first argument from user input.

| Argument | Mode | What it does |
| --- | --- | --- |
| (none) | **create** | Write/update the handoff doc for the current work |
| `resume` | **resume** | Read the existing handoff and bootstrap context for this session |
| `show` | **show** | Print the existing handoff doc unchanged, then stop |
| `path` | **path** | Print the resolved storage path and stop |

## Common: resolve the storage path

Always start with the helper. Never construct the path yourself.

```bash
result=$(~/.claude/skills/handoff/scripts/handoff-path.sh)
status=$(echo "$result" | cut -f1)   # existing | new
path=$(echo "$result"   | cut -f2)
scope=$(echo "$result"  | cut -f3)   # repo:org/name or dir:/abs/path
```

The helper writes to `<repo-root>/.notes/handoff.md` inside a git repo, or `~/.claude/handoff/dir-<hash>.md` outside one.

---

## Create mode (no argument)

This is the default. Write a handoff doc tuned for the *next Claude session*.

### Step 1: Confirm the scope

Tell the user the resolved scope (e.g., "Writing handoff for `repo:haacked/dotfiles` at `.notes/handoff.md`.").

If `status` is `existing`, **archive the previous handoff** before writing the new one so a trail is preserved. Read the old one first (you may want to carry forward still-relevant content like references or ruled-out approaches), then archive it:

```bash
archived=$(~/.claude/skills/handoff/scripts/handoff-archive.sh "$path")
```

The archive script moves the file to `<dir>/handoff-archive/<basename>-<YYYYMMDD-HHMMSS>.md` and prints the new path. Mention to the user that you archived the previous one and where it went.

### Step 2: Bail if there's nothing to hand off

If the conversation contains no concrete work (no files read, no commands run, no decisions made), tell the user:

> No session work to hand off yet. Run `/handoff` again after you've made progress.

Then stop. Do not write a placeholder handoff.

### Step 3: Gather state actively

Do not write the handoff from memory of the conversation. Memory produces narrative; state produces handoffs. Before filling any section, gather concrete state:

- Run `git diff HEAD --stat` and `git status` to get an overview of what changed.
- For files central to the handoff, read them directly with the Read tool (or run `git diff HEAD -- <path>` for a focused diff). Do not load the full unbounded diff.
- Read the files you've been working in (don't trust your recall of their current contents).
- Re-run failing tests or commands you've mentioned, so the verification section reflects reality.

Then capture the git snapshot for embedding:

```bash
~/.claude/skills/handoff/scripts/handoff-snapshot.sh
```

This emits a markdown block with branch, HEAD, upstream, and the dirty working tree. Embed it verbatim under the `## Snapshot` heading.

### Step 4: Fill the template

Start from `~/.claude/skills/handoff/templates/handoff.md`. Fill every section from the state you just gathered, not from conversation memory. Optimize for *the next Claude session* specifically:

- **Pointers over prose.** Cite `file.ts:42` instead of paraphrasing code. The next session can read.
- **Decisions over events.** Don't narrate the session ("first I tried X, then Y"). Record outcomes: what we chose, why, what was ruled out.
- **Concrete next action.** Name the file, the function, the failing test. "Continue the refactor" is wrong; "edit `foo.ts:42` to handle the null case, then run `pnpm test bar.spec.ts`" is right.
- **Decay-aware.** The snapshot timestamps the doc. Don't pretend it stays fresh: the doc tells the reader to trust the code over the doc if they conflict.
- **One page.** If you're past ~1 page, the doc is wrong: split the work smaller or commit in-progress state to a branch and let the diff carry the load.

Anti-example pair, internalize the difference:

- ❌ "We spent the session trying to understand why the tests fail."
- ✅ "`foo.ts:42` throws when `opts` is null; `pnpm test bar.spec.ts` currently fails at line 67."

Sections to fill (see template for prompts):

1. **Goal** (one sentence, outcome not task)
2. **Status** (concrete bullets: ✅ works, 🚧 in progress, ❌ broken)
3. **Next action** (file:line specific)
4. **Open decisions** (options + tradeoff + leaning, or "None.")
5. **Ruled out** (approach + one-line reason)
6. **Verification** (copy-pasteable commands)
7. **Key locations** (file paths + one-line what's there)
8. **Gotchas** (non-obvious traps, or "None.")
9. **References** (PR/issue/Slack links, or omit section)

Deliberately exclude: diff dumps, session narrative, re-explanations of readable code, speculation about future phases.

### Step 5: Write the file

```bash
mkdir -p "$(dirname "$path")"
```

Then write the filled-in markdown to `$path`. If a `.notes/` directory exists alongside the file, verify it's gitignored (warn the user if not).

### Step 6: Report

Tell the user the path you wrote. One line. Suggest next steps:

> Wrote handoff to `<path>`. Next session: open this repo and run `/handoff resume`.

---

## Resume mode (`resume`)

Bootstrap the current session from an existing handoff.

### Step 1: Read

If `status` is `new`, tell the user no handoff exists for this scope and stop.

Otherwise, read the file at `$path`.

### Step 2: Reconcile with current state

Run `handoff-snapshot.sh` again and compare to the snapshot embedded in the doc:

- **Same branch + HEAD**: doc is fresh, proceed.
- **Same branch, HEAD moved**: warn the user that work happened since the handoff was written. Suggest running `git log <doc-head>..HEAD` to see what changed.
- **Different branch**: ask the user whether to switch branches or treat the handoff as reference only. In reference-only mode, present Goal and Ruled out as probably still valid; treat Status, Next action, and Snapshot as stale and skip them in the summary.
- **Working tree differs from snapshot**: note it, don't block.

Also check relevance: if the handoff's Goal has no relationship to the current working directory or recent git activity, say so explicitly:

> This handoff describes [goal] but current state suggests different work. Treat as reference only, or archive it and start fresh.

### Step 3: Summarize and propose action

Give the user a tight summary:

- Goal (verbatim from doc)
- Status (verbatim, unless reference-only mode)
- The **Next action** the doc names (unless reference-only mode)

Then propose: "Do you want me to start on the next action, or do something else first?" Do not begin the work unilaterally, resuming is the user's call.

### Step 4: Offer to archive (after the user decides)

Hold the archive question until the user has confirmed what they want to do next (accept the proposed action, name a different action, or say they're unsure). Then offer to archive:

```bash
archived=$(~/.claude/skills/handoff/scripts/handoff-archive.sh "$path")
```

Default to yes since a stale doc on disk encourages re-loading outdated state. Report the archive path so the user knows the trail exists. If the user is still deciding or declines, leave the file in place.

---

## Show mode (`show`)

Just print the file contents and stop. No interpretation, no reconciliation. Use when the user wants to see the handoff without acting on it.

If the file doesn't exist, say so and stop.

---

## Path mode (`path`)

Print the resolved storage path and the scope. One line. Use when the user wants to know where the handoff lives (e.g., to gitignore it or open it in an editor).

---

## Boundary: /handoff vs /note vs plans

| Use `/handoff` for | Use `/note` for | Use a plan for |
| --- | --- | --- |
| Mid-task session bridges | Permanent technical discoveries | Multi-stage implementation roadmap |
| Disposable, repo-scoped, single file | Indefinite, slug-named, many files | Phased, stage-by-stage |
| Lives in `.notes/handoff.md` | Lives in `~/dev/.../notes/` | Lives in `~/dev/.../plans/` |
| Next-session-readable | Future-dev-readable | Implementer-readable |

If the handoff outgrows one page or starts capturing knowledge that outlives the task, promote the relevant parts to `/note` (technical) or a plan (multi-stage work) and keep the handoff tight.
