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

Scan back through this conversation for the most recent code review activity — output from `/review-code`, `/address-pr-reviews`, `/review-fix-cycle`, an ad hoc review, or PR comment triage. Pull out every item that fits either bucket:

**Open** — the review flagged it but left the call to you:

- Findings tagged `` `question` `` (review-code's convention: informational, not necessarily a problem, never auto-actioned)
- Anything phrased as "your call," "up to you," "judgment call," or a similar hedge
- PR comments assessed as not-legit but held for your review rather than auto-replied (`address-pr-reviews` does this for human reviewers)

**Skipped** — the review or a fix pass declined to act on it:

- `` `suggestion` `` or `` `nit` `` findings that were raised but never applied
- Entries logged in `.notes/review-skipped.md`
- PR comments marked "not legit" and dismissed

If nothing in the conversation fits either bucket, say so plainly and stop. Don't invent items to fill the response.

### If an argument was given

1. If the argument is an existing file path, read it directly as the review source and skip to Step 2.
2. Otherwise, resolve it to a repo/PR:

   ```bash
   ~/.dotfiles/bin/detect-pr.sh "$ARGUMENTS"
   ```

   If that fails because the argument isn't a PR reference, treat it as a branch name instead.

3. Locate the review file for that target:

   ```bash
   ~/.claude/skills/review-code/scripts/review-file-path.sh <identifier>
   ```

   Parse the JSON `file_path` field. If `file_exists` is true, read the file and pull out `` `question` `` findings plus any `` `suggestion` ``/`` `nit` `` findings not marked as fixed.

4. Check for a skipped-items log in the repo:

   ```bash
   cat "$(git rev-parse --show-toplevel)/.notes/review-skipped.md" 2>/dev/null
   ```

   Include any entries found there.

5. If nothing turns up from any of these sources, tell the user no open or skipped items were found for that target, and stop.

## Step 2: Explain Each Item

For every item gathered in Step 1, produce one block:

```markdown
### <N>. <short title> (`<file>:<line>` if known)

**What it means:** <plain-English explanation, no jargon — write for someone who hasn't read the diff>

**If you fix it:** <the benefit, plus any real cost: effort, risk, scope creep>
**If you leave it:** <the concrete consequence — what could go wrong, how likely, how bad, or "nothing, it's cosmetic">

**Recommendation:** **Fix it** / **Leave it** / **Your call** — <one-sentence reason>
```

Guidelines:

- Write "What it means" for a reader without the diff in front of them. Translate the technical finding; don't restate it.
- Make both impact lines concrete, not generic — "could cause a subtle bug under concurrent writes" beats "could be risky." If a side genuinely has no downside, say so plainly instead of padding it.
- Default to a real recommendation. Use "Your call" only when the tradeoff is genuinely balanced (e.g., two valid style preferences, unclear product intent), and say why it's a toss-up.
- Keep each block tight: a few sentences total, not a wall of text.

## Step 3: Summarize

After all items, show a one-line count: `N open, M skipped`.

Ask the user which items, if any, they'd like acted on now. Do not fix, reply to, or dismiss anything without their say-so — this skill only explains and recommends.
