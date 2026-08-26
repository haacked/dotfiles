---
name: comment-cleanup
description: Delete and tighten code comments in source files after they are written. Drops narration, restatement, and change-log comments, then cuts the survivors to one fact each. Use when the user says the comments are too wordy, asks to clean up or trim comments, or right after generating code that came out over-commented. Not for PR descriptions, review comments, or other prose; use plain-writing for those.
argument-hint: "[<path>…] [--staged|--branch] [--all] [--report]"
model: sonnet
metadata:
  execution-tier: balanced
---

# Comment Cleanup

Authoring-time rules do not hold on their own; a model that just worked out a mechanism reliably over-explains it. This is the pass that runs afterward, over comments that already exist.

The standard is the Style section of `AGENTS.md`. The code shows how it works, so a comment earns its place only by carrying what the code cannot: a constraint, a deliberate deviation, a gotcha, a workaround. This skill enforces that by deleting, not by rewriting everything it finds.

## Reading the Arguments

- `paths` = any non-flag arguments. Given, they replace the default scope, and every comment in them is in scope.
- `--staged` scopes to the staged diff. `--branch` scopes to commits since the merge-base with the default branch.
- With no path and no scope flag, the scope is the working-tree diff plus commits since the merge-base with the default branch.
- `--all` widens a diff scope from comments the diff touched to every comment in the files the diff touched.
- `--report` prints the decisions and changes nothing.

Never widen past the requested scope. A comment nobody touched is someone else's judgment call, and rewriting it buries the real change in noise.

## Steps

### 1. Collect the comments

Read the files in scope. For each comment, note its file, line, text, and whether it is a **doc comment** (the language's documented position and format on a declaration: godoc, JSDoc, rustdoc, XML doc, a Python docstring) or an **inline comment** (everything else, including a block comment sitting above a statement inside a function).

The two kinds have different standards. Doc comments are API surface that tooling consumes and readers reach for without opening the file. Inline comments are the ones that accumulate.

### 2. Leave these alone

These are code wearing a comment's syntax, and deleting one changes behavior:

- Lint and compiler directives: `# noqa`, `# type: ignore`, `eslint-disable`, `// nolint`, `#pragma`, `@ts-expect-error`, `SPDX-License-Identifier`.
- Shebangs, encoding declarations, build tags, and file-level license or copyright headers.
- Anything inside a generated file, plus the header that marks it generated.
- `TODO`/`FIXME`/`HACK` markers that name an issue, ticket, or owner. One with no reference is a normal comment; judge it on its content.
- Commented-out code. Report it, do not delete it. Whether it is dead or parked is the author's call.

### 3. Decide each remaining comment

First match wins.

1. **Restates its line.** The comment says what the code next to it already says, at the same level of detail (`// increment the counter` over `counter += 1`; `// loop over users`; `// parse the body`). Delete. This is the largest category by far.
2. **Restates a name, type, or signature.** An inline comment repeating what the declaration on the next line spells out. Delete. A doc comment does this legitimately; leave it to rule 7.
3. **Narrates the change.** `fixed X`, `updated to Y`, `now uses Z`, `as requested`, `changed from the old approach`. Delete, or if the comment carries a fact worth keeping, rewrite it as final state per the Style rule: what the code does now, never what it replaced.
4. **Leaks reasoning.** The model's own working shown to the reader: `we need to be careful here`, `this is important because`, a recap of an alternative that was considered and dropped. Delete. A constraint that ruled the alternative out can survive as one sentence if a reader would otherwise reintroduce the bug.
5. **Marks structure.** End-of-block markers, section banners, `// helpers below`, a header restating the function it opens. Delete.
6. **Contradicts the code.** Stale, describing behavior that is no longer there. Fix it if the correct fact is clear from the code; delete it if not. A stale comment is worse than none.
7. **Earns its place but sprawls.** Multi-sentence rationale, a paragraph where a clause does, or a mechanism spelled out that the line itself already shows. Cut to the single non-obvious fact a reader needs at that line, in one sentence. For a doc comment, cut to a one-line summary plus whatever contract the caller cannot see: raised errors, units, nullability, ordering, thread safety.
8. **Reads as a label.** A compact phrase standing in for a mechanism, where a reader who does not already know it cannot say what changes state. Expand it to what happens, in one sentence, per the Style rule. This is the one case that gets longer, and only after the comment has survived rules 1 through 7.
9. **Uncertain.** Keep it, unchanged.

Rule 9 is deliberately asymmetric. A redundant comment left in place costs a reader two seconds. A deleted warning costs someone an outage. When you cannot tell whether a comment encodes a real constraint, it does.

### 4. Apply and report

Under `--report`, print the table and stop. Otherwise make the edits, then print it:

| File:line | Was | Action | Why |
| --- | --- | --- | --- |
| `sync.py:42` | `# increment the counter` | deleted | restates its line |
| `queue.go:88` | `// holds the batch` | rewrote | label, expanded to what happens |
| `api.ts:15` | `// retry twice, the gateway 502s on cold start` | kept | non-obvious constraint |

Then a count: deleted, rewrote, kept. List commented-out code and anything rule 9 held separately, so the author can rule on it.

Do not commit. Do not touch code that is not a comment. If a comment can only be fixed by changing the code it describes, say so in the report and leave both alone.
