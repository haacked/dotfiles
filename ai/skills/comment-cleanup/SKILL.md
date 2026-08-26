---
name: comment-cleanup
description: Delete and tighten code comments in source files after they are written. Drops narration, restatement, and change-log comments, then cuts the survivors to one fact each. Use when the user says the comments are too wordy, asks to clean up or trim comments, or right after generating code that came out over-commented. Not for PR descriptions, review comments, or other prose; use plain-writing for those.
argument-hint: "[<path>…] [--branch] [--parent <ref>] [--all] [--dry-run]"
model: sonnet
metadata:
  execution-tier: balanced
---

# Comment Cleanup

Authoring-time rules do not hold on their own; a model that just worked out a mechanism reliably over-explains it. This is the pass that runs afterward, over comments that already exist.

The standard is the Style section of `AGENTS.md`. The code shows how it works, so a comment earns its place only by carrying what the code cannot: a constraint, a deliberate deviation, a gotcha, a workaround. This skill enforces that by deleting, not by rewriting everything it finds.

## Reading the Arguments

- With no arguments, the scope is the uncommitted working-tree diff, staged and unstaged both (`git diff HEAD`). That is the work just done, which is what the pipelines that call this skill mean by "the changes just made".
- `paths` = any non-flag arguments. Given, they replace that scope, and every comment in those files is in scope.
- `--branch` widens to every commit on this branch. Resolve the base with the repo's stack-aware helper rather than assuming the default branch, so a stacked branch does not pull in the parent PR's commits:

```bash
eval "$(bash "$HOME/.dotfiles/bin/lib/git-pr-base.sh")"   # append --parent <ref> if the user passed one
git diff "$REF"...HEAD
```

  If the helper is unavailable or leaves `REF` empty, say so and stop rather than falling back to a guess. Report `NOTES` to the user when it is non-empty.

- `--parent <ref>` overrides the base the helper picks. Only meaningful with `--branch`.
- `--all` widens a diff scope from the comments the diff touched to every comment in the files it touched. It changes nothing when explicit paths were given, since those are already whole files.
- `--dry-run` prints the decisions and changes nothing.

Never widen past the requested scope. Outside `--all` and explicit paths, a comment the diff did not touch is someone else's judgment call.

## Steps

### 1. Collect the comments

Read the diff hunks for the scope. Under a diff scope the hunk carries the comment and the code it sits next to, which is all the delete rules need; read the whole file only when a comment's fate turns on something further away, and always under `--all` or an explicit path.

### 2. Leave these alone

These are code wearing a comment's syntax, and deleting one changes behavior:

- Lint and compiler directives: `# noqa`, `# type: ignore`, `eslint-disable`, `// nolint`, `#pragma`, `@ts-expect-error`, `SPDX-License-Identifier`.
- Shebangs, encoding declarations, build tags, and file-level license or copyright headers.
- Anything inside a generated file, plus the header that marks it generated.
- `TODO`/`FIXME`/`HACK` markers that name an issue, ticket, or owner. One with no reference is a normal comment; judge it on its content.
- Commented-out code. Report it, do not delete it. Whether it is dead or parked is the author's call.

### 3. Hold doc comments to their own standard

A doc comment is the language's documented form on a declaration: godoc, JSDoc, rustdoc, XML doc, a Python docstring. It is API surface that tooling renders and callers read without opening the file, so restating the signature is its job, and the delete rules in Step 4 do not apply to it.

Cut it to a one-line summary plus the contract a caller cannot see: raised errors, units, nullability, ordering, thread safety. Delete nothing a linter or a doc build requires, and never trade a doc comment for silence just because the name reads clearly.

### 4. Decide each inline comment

Everything Step 2 and Step 3 did not claim. Take the first rule that **clearly** matches.

Clearly is the operative word, and it governs every rule below rather than waiting at the end as a last resort. When you cannot tell whether a rule matches, none of them do, and the comment stays exactly as written. A redundant comment costs a reader seconds; a deleted warning costs an outage. Where a comment might encode a real constraint, assume it does.

1. **Restates the code next to it.** The comment says what the adjacent line already says, at the same level of detail (`// increment the counter` over `counter += 1`; `// loop over users`), or repeats the name, type, or signature it sits above. Delete. This is the largest category by far.
2. **Narrates the change.** `fixed X`, `updated to Y`, `now uses Z`, `as requested`, `changed from the old approach`. Delete, or if it carries a fact worth keeping, rewrite as final state per the Style rule: what the code does now, never what it replaced.
3. **Leaks reasoning.** The model's own working shown to the reader: `we need to be careful here`, `this is important because`, a recap of an alternative that was considered and dropped. Delete. A constraint that ruled the alternative out can survive as one sentence if a reader would otherwise reintroduce the bug.
4. **Marks structure.** End-of-block markers, section banners, `// helpers below`, a header restating the function it opens. Delete.
5. **Contradicts the code.** Stale, describing behavior that is no longer there. Fix it if the correct fact is clear from the code; delete it if not. A stale comment is worse than none.
6. **Earns its place but sprawls.** Multi-sentence rationale, a paragraph where a clause does, or a mechanism spelled out that the adjacent line already shows. Cut to the single non-obvious fact a reader needs at that line, in one sentence.
7. **Reads as a label.** A compact phrase standing in for a mechanism, where a reader who does not already know it cannot say what changes state. Expand it to what happens, in one sentence, per the Style rule. This is the one rule that makes a comment longer, and it fires only when rules 1 through 6 have all missed.

Rules 1 and 7 divide on one question: can a reader work the fact out from the code in front of them? `// holds the batch` over `self.pending.append(batch)` is rule 1, because the line says it. The same phrase over `flush_deadline = None` is rule 7, because nothing nearby says what holding does to the batch.

### 5. Apply and report

Under `--dry-run`, print the report and stop. Otherwise make the edits, then print it.

List only what changed, so the report stays proportional to the edits rather than to the comments read:

| File:line | Was | Action | Why |
| --- | --- | --- | --- |
| `sync.py:42` | `# increment the counter` | deleted | restates its line |
| `queue.go:88` | `// holds the batch` | rewrote | label over unrelated state, expanded |

Then one count line: deleted, rewrote, kept.

Then, separately, the items the author has to rule on: comments a rule nearly matched but not clearly, and the commented-out code from Step 2. A caller that persists anything persists this list, so keep it short and name the file and line for each.

Do not commit. Do not touch code that is not a comment. If a comment can only be fixed by changing the code it describes, say so in the report and leave both alone.
