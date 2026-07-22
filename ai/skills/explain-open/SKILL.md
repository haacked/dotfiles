---
name: explain-open
description: Explain each open or skipped code-review item in plain English, weigh what happens on each side of the decision, and give a recommendation.
argument-hint: "[<pr-url>|<pr-number>|<branch>|<file>]"
model: sonnet
---

# Explain Open Items

Code reviews leave two kinds of loose ends: items explicitly flagged as open questions for you to decide, and items a fix pass declined to act on. Instead of re-reading the raw finding and puzzling out what it actually means, this skill translates each one into plain English, spells out what happens on each side of the decision, and recommends a call.

**Arguments (optional):**

- No argument — use the code review already visible in this conversation. This is the common case: you just ran a review and want the loose ends explained before deciding.
- `<pr-url>` or `<pr-number>` — look up that PR's review artifacts.
- `<branch>` — look up that branch's review artifacts.
- `<file>` — read a specific review file directly (e.g. a saved `/review-code` output or `.notes/review-skipped.md`).

Example invocations:

- `/explain-open` — explain the open/skipped items from the review just discussed
- `/explain-open 456` — explain open/skipped items for PR #456
- `/explain-open feature-branch` — explain open/skipped items for that branch's review
- `/explain-open .notes/review-skipped.md` — explain items from a specific file

## Step 1: Gather the Open and Skipped Items

### If no argument was given

Scan back through this conversation for code review activity — output from `/review-code`, `/address-pr-reviews`, `/review-fix-cycle`, an ad hoc review, or PR comment triage.

- If exactly one review is visible, use it.
- If more than one review appears (e.g., you reviewed one PR earlier, then separately reviewed another), use only the most recent one. Items from an earlier review are likely stale or about a different target, and mixing them in produces a confusing, ungrounded list. If it's genuinely unclear which of several reviews is the current one, ask which target to use rather than guessing or merging both.
- If the conversation has been compacted or summarized and you can't recover the specific findings (file, line, exact wording) from what's actually in context, say so rather than filling in detail from a vague summary. Suggest re-running the review, or invoking `/explain-open <pr-or-branch-or-file>` to read the saved review file directly.

Pull out every item that fits either bucket:

**Open** — the review flagged it but left the call to you:

- Findings tagged `` `question` `` (review-code's convention: informational, not necessarily a problem, never auto-actioned)
- Anything phrased as "your call," "up to you," "judgment call," or a similar hedge
- PR comments assessed as not-legit but held for your review rather than auto-replied (`address-pr-reviews` does this for human reviewers)

**Skipped** — the review or a fix pass declined to act on it:

- `` `suggestion` `` or `` `nit` `` findings that were raised but never applied. Check whether a later point in the conversation shows the item actually being fixed (an edit, a diff, a commit); if so it's resolved, not skipped.
- Entries logged in `.notes/review-skipped.md`
- PR comments marked "not legit" and dismissed

If nothing in the conversation fits either bucket, say so plainly and stop. Don't invent items to fill the response.

### If an argument was given

1. If the argument is an existing file (checked relative to the current working directory), read it directly as the review source and skip to Step 2. This takes priority even if the same string would also parse as a PR number or look like a branch name.

2. Otherwise, classify the argument:

   - **It's a GitHub PR URL** (`https://github.com/<owner>/<repo>/pull/<number>`) — resolve it:

     ```bash
     ~/.dotfiles/bin/detect-pr.sh --json "$ARGUMENTS"
     ```

     This always exits 0 and prints JSON. If `error` is null, use `org`, `repo`, and `pr_number` from the result: the identifier for step 3 is `pr-<pr_number>`, passed alongside `--org <org> --repo <repo>` (the PR may belong to a different repo than the current checkout). If `error` is set, tell the user the PR reference looks malformed and stop; don't fall through to treating it as a branch name.

   - **It's a bare integer** (e.g. `456`) — use it directly as the identifier in step 3, with no `--org`/`--repo`. Don't call `detect-pr.sh`; `review-file-path.sh` resolves bare PR numbers against the current git checkout on its own.

   - **Anything else** — treat it as a branch name. Use `$ARGUMENTS` directly as the identifier in step 3, with no `--org`/`--repo`. Don't call `detect-pr.sh` here: it only resolves PR URLs or numbers and rejects everything else, so calling it first just adds a step that's guaranteed to fail.

3. Locate the review file:

   ```bash
   ~/.claude/skills/review-code/scripts/review-file-path.sh [--org <org> --repo <repo>] <identifier>
   ```

   (Include `--org`/`--repo` only for the PR-URL case above.) Parse the JSON output. If `file_exists` is true, read `file_path` and pull out `` `question` `` findings plus any `` `suggestion` ``/`` `nit` `` findings not marked as fixed.

4. Check for a skipped-items log in the repo:

   ```bash
   cat "$(git rev-parse --show-toplevel)/.notes/review-skipped.md" 2>/dev/null
   ```

   Skip this check if step 2 passed `--org`/`--repo` for a repo different from the current checkout; there's no local worktree to look in for that case. Otherwise, include any entries found there.

5. If nothing turns up from any of these sources, tell the user no open or skipped items were found for that target, and stop.

## Step 2: Explain Each Item

Group items under two headings, each numbered from 1. Omit a heading entirely if that bucket is empty.

```markdown
## Open Items

### 1. <short title> (`<file>:<line>` if known)

**What it means:** <plain-English explanation, no jargon — write for someone who hasn't read the diff>

**If you fix it:** <the benefit, plus any real cost: effort, risk, scope creep>
**If you leave it:** <the concrete consequence — what could go wrong, how likely, how bad, or "nothing, it's cosmetic">

**Recommendation:** **Fix it** / **Leave it** / **Your call** — <one-sentence reason>

## Skipped Items

### 1. <short title> (`<file>:<line>` if known)

(same block shape as above)
```

Guidelines:

- Write "What it means" for a reader without the diff in front of them. Translate the technical finding; don't restate it.
- Make both impact lines concrete, not generic — "could cause a subtle bug under concurrent writes" beats "could be risky." If a side genuinely has no downside, say so plainly instead of padding it.
- Default to a real recommendation. Use "Your call" only when the tradeoff is genuinely balanced (e.g., two valid style preferences, unclear product intent), and say why it's a toss-up.
- Keep each block tight: a few sentences total, not a wall of text.

## Step 3: Summarize

After all items, show a one-line count: `N open, M skipped`.

Ask the user which items, if any, they'd like acted on now. Do not fix, reply to, or dismiss anything without their say-so — this skill only explains and recommends.
