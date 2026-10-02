---
name: explain-open
description: Explain each unanswered decision the agent asked the user to make, and each open or skipped code-review item, in plain English; weigh what happens on each side of the decision and give a recommendation.
argument-hint: "[<pr-url>|<pr-number>|<branch>|<file>]"
model: sonnet
metadata:
  execution-tier: balanced
---

# Explain Open Items

A session leaves three kinds of loose ends: decisions the agent asked you to make that you haven't answered, review items explicitly flagged as open questions for you to decide, and review items a fix pass declined to act on. Instead of scrolling back to find each question or re-reading the raw finding to puzzle out what it means, this skill translates each one into plain English, spells out what happens on each side of the decision, and recommends a call.

**Arguments (optional), which choose where the review items come from:**

- No argument — use the code review already visible in this conversation. This is the common case: you just ran a review and want the loose ends explained before deciding.
- `<pr-url>` or `<pr-number>` — look up that PR's review artifacts.
- `<branch>` — look up that branch's review artifacts.
- `<file>` — read a specific review file directly (e.g. a saved `review-code` output or `.notes/review-skipped.md`).

## Step 1: Gather Decisions and Review Items

Gather the two lists separately. Open decisions always come from this conversation, even when an argument names a target. Either list may come up empty, and only Step 2 decides whether to stop.

If the conversation has been compacted and you can't recover the specifics from what's in context (a decision's question and options, or a finding's file, line, and wording), say so rather than filling them in from a summary.

### Open decisions

Scan this conversation for decisions you asked the user to make about what to do next, whether you asked in prose or through a structured question prompt.

Include:

- A question that offers a choice the user has not answered, such as "Fold the fixup into the existing commit, or keep it separate?" or "Push now, or wait until the base PR settles?"
- A recommendation you made that waits on the user's go-ahead, such as "I'd update the PR description in the same push. Want me to?", when the user has not confirmed it.
- Each part of a multi-part question, as its own decision. The user may answer one part and leave the others open.

Leave out:

- A decision the user answered. An instruction that implies one of the options, or a reply that rejects the options in favor of a different course, also answers it. A reply that only moves on to other work leaves the decision open.
- A decision a later action settled. If you pushed after asking whether to push, that decision is closed.
- A question that offers no choice, such as "Anything else?"

### Review items, if no argument was given

Scan back through this conversation for code review activity — output from `review-code`, `address-pr-reviews`, `review-fix-cycle`, an ad hoc review, or PR comment triage.

- If exactly one review is visible, use it.
- If more than one review appears (e.g., you reviewed one PR earlier, then separately reviewed another), use only the most recent one. Items from an earlier review are likely stale or about a different target, and mixing them in produces a confusing, ungrounded list. If it's genuinely unclear which of several reviews is the current one, ask which target to use rather than guessing or merging both.
- If compaction lost the review's findings, suggest re-running the review, or invoking the skill with the target (`$explain-open <pr-or-branch-or-file>` in Codex or `/explain-open <pr-or-branch-or-file>` in Claude Code) to read the saved review file directly.

Pull out every item that fits either bucket:

**Open** — the review flagged it but left the call to you:

- Findings tagged `` `question` `` (review-code's convention: informational, not necessarily a problem, never auto-actioned)
- Anything phrased as "your call," "up to you," "judgment call," or a similar hedge
- PR comments assessed as not-legit but held for your review rather than auto-replied (`address-pr-reviews` does this for human reviewers)

**Skipped** — the review or a fix pass declined to act on it:

- `` `suggestion` `` or `` `nit` `` findings that were raised but never applied. Check whether a later point in the conversation shows the item actually being fixed (an edit, a diff, a commit); if so it's resolved, not skipped.
- Entries logged in `.notes/review-skipped.md`
- PR comments marked "not legit" and dismissed

### Review items, if an argument was given

1. If the argument is an existing file (checked relative to the current working directory), read it directly as the review source and skip to Step 2. This takes priority even if the same string would also parse as a PR number or look like a branch name.

2. Otherwise, classify the argument:

   - **It's a GitHub PR URL** (`https://github.com/<owner>/<repo>/pull/<number>`) — resolve it:

     ```bash
     ~/.dotfiles/bin/detect-pr.sh --json "<argument>"
     ```

     This always exits 0 and prints JSON. If `error` is null, use `org`, `repo`, and `pr_number` from the result: the identifier for step 3 is `pr-<pr_number>`, passed alongside `--org <org> --repo <repo>` (the PR may belong to a different repo than the current checkout). If `error` is set, tell the user the PR reference looks malformed and skip the rest of this list; don't fall through to treating it as a branch name.

   - **It's a bare integer** (e.g. `456`) — use it directly as the identifier in step 3, with no `--org`/`--repo`. Don't call `detect-pr.sh`; `review-file-path.sh` resolves bare PR numbers against the current git checkout on its own.

   - **Anything else** — treat it as a branch name. Use the provided argument directly as the identifier in step 3, with no `--org`/`--repo`. Don't call `detect-pr.sh` here: it only resolves PR URLs or numbers and rejects everything else, so calling it first just adds a step that's guaranteed to fail.

3. Locate the review file:

   ```bash
   ~/.agents/skills/review-code/scripts/review-file-path.sh [--org <org> --repo <repo>] <identifier>
   ```

   If `review-code` is not installed there, tell the user that target lookup requires that skill and skip the rest of this list. Include `--org`/`--repo` only for the PR-URL case above. Parse the JSON output. If `file_exists` is true, read `file_path` and pull out `` `question` `` findings plus any `` `suggestion` ``/`` `nit` `` findings not marked as fixed.

4. Check for a skipped-items log in the repo:

   ```bash
   cat "$(git rev-parse --show-toplevel)/.notes/review-skipped.md" 2>/dev/null
   ```

   Skip this check if step 2 passed `--org`/`--repo` for a repo different from the current checkout; there's no local worktree to look in for that case. Otherwise, include any entries found there.

## Step 2: Explain Each Item

Reconcile the two lists first:

- If a decision restates a review finding, keep it only as the review item.
- Drop any review item the user already decided in this conversation, such as a `` `question` `` finding you put to them that they answered.

If no open decisions and no review items remain, say so plainly and stop. When an argument named a target and its lookup ran, say that no open or skipped items were found for that target. When the lookup failed, Step 1 already told the user why, so don't add that line. Don't invent items to fill the response.

Group items under three headings in the order below, each numbered from 1. Omit a heading entirely if that bucket is empty.

```markdown
## Open Decisions

### 1. <short title for the choice>

**What it means:** <what is being decided, why it came up, and what each option does, in plain English>

**If you <first option>:** <what happens>
**If you <second option>:** <what happens>
(one line per option)

**Recommendation:** **<option>** / **Your call**: <one-sentence reason>

## Open Items

### 1. <short title> (`<file>:<line>` if known)

**What it means:** <plain-English explanation, no jargon — write for someone who hasn't read the diff>

**If you fix it:** <the benefit, plus any real cost: effort, risk, scope creep>
**If you leave it:** <the concrete consequence — what could go wrong, how likely, how bad, or "nothing, it's cosmetic">

**Recommendation:** **Fix it** / **Leave it** / **Your call**: <one-sentence reason>

## Skipped Items

### 1. <short title> (`<file>:<line>` if known)

(same block shape as Open Items)
```

Guidelines:

- Make each impact line concrete, not generic: "could cause a subtle bug under concurrent writes" beats "could be risky." If a side genuinely has no downside, say so plainly instead of padding it.
- For a decision, write one impact line per option, such as "If you fold:" and "If you keep them separate:". A yes-or-no decision has two options: doing it and not doing it.
- If you recommended an option when you asked, keep that recommendation unless something since then changes it. If something did, say what changed.
- Default to a real recommendation. Use "Your call" only when the tradeoff is genuinely balanced (e.g., two valid style preferences, unclear product intent), and say why it's a toss-up.

## Step 3: Summarize

After all items, show a one-line count: `D decisions, N open, M skipped`. If the target lookup failed, replace the review counts with the reason, such as `2 decisions; review items not loaded (review-code is not installed)`.

Ask the user to answer the open decisions and to say which review items, if any, they'd like acted on now. Do not act on a decision, or fix, reply to, or dismiss anything, without their say-so. This skill only explains and recommends.
