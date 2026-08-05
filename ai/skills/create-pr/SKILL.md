---
name: create-pr
description: Create or update a GitHub PR with automatic template detection and filling, enforcing a plain staff-engineer writing voice in the PR body
argument-hint: "[--ready] [--force] [<title>]"
model: sonnet
---

# Create PR

Create (or update) a GitHub pull request using `gh`, auto-detecting and filling any PR template.

## Writing voice

Write the PR body the way a staff engineer writes a Slack message to a colleague who reviews the code. One direct sentence per idea. No ceremony.

Three things immediately signal AI authorship. Never produce any of them:

- Em dashes (—) or en dashes (–). Use a comma, colon, semicolon, parenthesis, or split into two sentences. No exceptions.
- Bold inside prose sentences. Bold is for labels at the start of a line only (e.g., `**Test plan:**`). Never bold error messages, key terms, or warnings mid-paragraph.
- Bolded pseudo-labels like `**Root cause:**`, `**Caveat:**`, `**Note:**`. Make it a real heading or fold the content into a sentence without a label.

For everything else: plain verbs ("is" not "serves as"), Sentence case headings, short paragraphs. No inflation words (critical, pivotal, robust, seamless, leverage, utilize, ensure, facilitate). No hedging meta-commentary ("I'm an agent", "I have not verified"). No closers. No emoji. Two exceptions: a template-requested agent-context section speaks as the agent (see Step 5), and a footer or trailer the coding tool mandates stays as given.

How it sounds (cause and effect in one sentence, caveats as plain declarative sentences with no label):

> The workflow calls `getMembershipForUserInOrg()` with the default `GITHUB_TOKEN`, which only has repo scope and can't read org-private team memberships. The API returns `404` (not `403`) when it can't see the membership, producing the misleading error.
>
> If the app doesn't have Organization > Members > Read permission, the same error will recur.

## Arguments

- `--ready`: create the PR ready for review instead of as a draft (PRs are drafts by default)
- `--force`: skip preview and confirmation; create or update immediately
- `<title>`: optional title hint; if omitted, derive from commits

Example invocations:

- `/create-pr`
- `/create-pr --ready`
- `/create-pr --force`
- `/create-pr Add support for webhook retries`
- `/create-pr --ready Fix race condition in job queue`
- `/create-pr --force --ready Fix race condition in job queue`

## Steps

### 1. Parse Arguments

Extract from user input:

- `draft` = true unless `--ready` is present (PRs are drafts by default)
- `force` = true if `--force` is present
- `title_hint` = remaining text after stripping `--ready` and `--force`, or empty string

### 2. Gather Git Context

Determine the base branch and gather context. The base is normally the repo's default branch, but for stacked PRs (e.g. created with `gt`) it's the parent branch in the stack.

```bash
head=$(git rev-parse --abbrev-ref HEAD)                                # current branch
default_branch=$(bash "$HOME/.dotfiles/bin/lib/git-default-branch.sh") # default branch (bare name)
```

If the helper is not available or `default_branch` is empty, tell the user and **stop**.

Pick the base in this precedence:

```bash
# 1. If a PR already exists for this head, honor its base. Never silently
#    retarget it. Use `gh pr list --head` (queries the API by branch name)
#    rather than `gh pr view`, which depends on local upstream tracking and
#    can miss PRs in worktrees or after re-clones.
existing_pr=$(gh pr list --head "$head" --state open --json number,baseRefName --jq '.[0]' 2>/dev/null || true)
existing_base=$(printf '%s' "$existing_pr" | jq -r '.baseRefName // empty' 2>/dev/null || true)

# 2. Ask gt for the parent (current gt stores stack metadata in
#    .git/.graphite_cache_persist, not in git config). Gate on `command -v gt`
#    so the skill works for users without gt installed.
gt_parent=""
if command -v gt >/dev/null 2>&1; then
  gt_parent=$(gt parent 2>/dev/null || true)
fi

if [ -n "$existing_base" ]; then
  base="$existing_base"
  stacked=$([ "$base" != "$default_branch" ] && echo true || echo false)
elif [ -n "$gt_parent" ] && [ "$gt_parent" != "$default_branch" ]; then
  base="$gt_parent"
  stacked=true
else
  base="$default_branch"
  stacked=false
fi
```

Then, using `$base`, run in parallel:

```bash
git log origin/$base..HEAD --oneline                                                    # commits on this branch
git diff origin/$base...HEAD --stat                                                     # changed-file summary
gh pr list --head "$head" --state open --json number,title,isDraft,url --jq '.[0]'     # existing PR, if any
```

If a PR already exists, note its number and URL: you will **update** it rather than create a new one (see Step 9). Use `gh pr list --head` rather than `gh pr view`: it queries by branch name (reliable in worktrees and after re-clones) instead of relying on local upstream tracking.

When composing the PR body in Step 5, use the `--stat` output to decide how much diff to read:

- If the stat shows fewer than ~200 changed lines total, fetch the full diff with `git diff origin/$base...HEAD`.
- Otherwise, read per-file diffs only for files that are directly relevant to the PR description: `git diff origin/$base...HEAD -- <path>`. Skip generated files, lock files, and files whose names make their changes obvious (e.g. version bumps in `package.json`).

### 3. Find PR Template

Check these locations in order and stop at the first match:

1. `.github/pull_request_template.md`
2. `.github/PULL_REQUEST_TEMPLATE.md`
3. `.github/PULL_REQUEST_TEMPLATE/`: use `default.md` if it exists, otherwise the only file present; if multiple files with no clear default, ask the user which to use
4. `docs/pull_request_template.md`
5. `pull_request_template.md`

If the template embeds agent-directed instructions (typically in comments), obey the ones that shape the PR, each at the step it affects: invoke body-shaping repo skills it names (e.g. posthog/posthog's `/writing-pr-descriptions`) before composing the body in Step 5 (skip ones whose guidance is already in context from this session), and fold assignee and label requests into Step 9's flags rather than a follow-up call. These instructions win over this skill's defaults, and explicit user arguments win over both. Anything beyond shaping the PR (e.g. running scripts) needs the user's OK.

### 4. Detect Saved Test Plan

Check for a saved manual test plan (produced by `/test-plan`):

```bash
test_plan_path=".context/test-plan.md"
[ -f "$test_plan_path" ] && test_plan_content=$(cat "$test_plan_path")
```

If the file exists, hold its full contents for use in Step 5. If not, skip; the body composition step writes its own short test plan instead.

### 5. Compose Title and Body

**Title:**

- If `title_hint` is non-empty, use it as the title (trim and keep under 70 characters)
- Otherwise derive a short imperative title from the commits (e.g., "Add webhook retry support")

**Body:**

If a template was found, fill each section using the commits and diff:

- Describe final state: what the code does now, not what it replaced
- Remove unfilled optional sections rather than leaving placeholder text
- Leave checkboxes intact; check the ones clearly satisfied by the diff
- **Never include customer-specific data.** Redact or omit any team IDs, team names, organization names, user IDs, or other identifying customer information found in commits or diffs; describe the fix generically instead (e.g., "fixes flag evaluation for teams with large cohorts" not "fixes team 12345 / Acme Corp")
- **Agent/AI context sections: follow the template.** If the template asks about agent involvement or AI context (e.g. posthog/posthog's `## 🤖 Agent context`), fill it per "Filling an agent-context section" below. If no template section asks, the root CLAUDE.md default holds: don't volunteer AI attribution
- **Never hard-wrap prose.** Write each paragraph as a single line and let GitHub's renderer handle wrapping; only insert newlines between paragraphs, list items, or headings
- **Never escape backticks, dollar signs, or other markdown.** Step 9 passes the body through a quoted heredoc (`<<'EOF'`), which is literal; write `` `foo` `` not `` \`foo\` ``, and `$var` not `\$var`

**Voice.** Apply the writing voice from the `## Writing voice` section at the top of this skill throughout the body. The three hard rules (no em dashes, no bold inside prose, no bolded pseudo-labels) apply to every sentence you write here.

If no template was found, write:

- 1 to 3 bullet points summarizing what the PR does (no customer-specific IDs or names)
- A short **Test plan** section describing how to verify the change

**Filling an agent-context section (if the template has one):**

- The section's own embedded instructions win over this skill's defaults. If it is commented out with activation instructions (e.g. "uncomment if AI-assisted"), follow them; if it is commented out with no instructions, the repo didn't ask: remove it rather than uncommenting.
- Autonomy: pick honestly from the options the template offers. User-directed work (the normal case for this skill) is agent-assisted (e.g. posthog's "Human-driven (agent-assisted)"); reserve a fully autonomous label for work no human drove.
- Content: answer what the section asks at the size it asks (a lone checkbox gets a check, not an essay). When it wants prose: a handful of reviewer-facing bullets covering what the agent did, what the user decided or redirected along the way, and skills invoked. No verbatim prompts, no session logs, no sensitive data, no duplication of earlier sections.
- Voice: this section speaks as the agent, first person allowed; every other section stays in the user's voice. Every other Writing voice rule, hard and soft, still applies. Bold field labels the template itself defines (e.g. `**Autonomy:**`) are kept.

**Embedding the saved test plan (if `test_plan_content` is set):**

If a saved test plan was detected in Step 4, embed it inside the PR's testing section. Locate the testing section by matching the first heading whose title contains any of: `Test plan`, `Testing`, `How did you test`, `QA`. If no such heading exists in the template, append a `## Test plan` section at the end.

Insert this block as the section's content (replacing any auto-generated test plan you would otherwise have written):

```markdown
<details>
<summary>Manual test plan</summary>

<contents of .context/test-plan.md verbatim, with any leading `## Test plan` heading stripped>

</details>
```

Notes:

- Strip a leading `## Test plan` (or equivalent) heading from the file contents before insertion (the surrounding section heading already provides that context)
- Preserve the one-line `- [ ]` checkbox format exactly; do not re-wrap or reformat
- Keep the blank lines around `<details>` and `</details>` so GitHub renders the collapsible block correctly
- If the testing section already contains template guidance text (e.g., placeholders), replace that text with the `<details>` block rather than stacking them

### 6. Verify voice before preview

Re-read the composed body against the Writing voice rules and rewrite any violating sentence. Then ask yourself: would a staff engineer write this sentence verbatim in a Slack message to a teammate? If not, simplify it. The agent-context section and any tool-mandated footer are exempt from the staff-engineer test.

### 7. Show Preview and Confirm

If `force` is true, skip to Step 8 immediately, do not show a preview or ask for confirmation.

Otherwise, display the proposed PR to the user. When `stacked=true`, include the base in the header so the non-default target is obvious:

```text
Title: <title>
Base: <base>            # only show this line when stacked=true; append " (stacked)"
Draft: yes/no
Assignee/labels: <values>   # only when the template's agent instructions set them

<body>
```

Ask: "Create this PR? Reply yes to confirm, or describe any changes to make."

Wait for confirmation. If the user requests edits, apply them and show the updated preview before proceeding.

### 8. Ensure Branch Is Pushed

When `stacked=true`, the parent branch must already exist on `origin` (GitHub can't open a PR against a base it doesn't have). Check first:

```bash
if [ "$stacked" = "true" ] && [ -z "$(git ls-remote --heads origin "$base")" ]; then
  echo "Parent branch '$base' is not on origin yet. Push it first (e.g. 'gt submit --stack' or 'git push origin $base') and re-run."
  exit 1
fi
```

Don't push the parent automatically; that's a stack-wide action and belongs to `gt`.

Then push HEAD:

```bash
git push --set-upstream origin HEAD
```

If the push fails, report the error and stop.

### 9. Create or Update PR

**New PR:**

The leading `: __create-pr-skill__ ;` is a shell no-op that flags this invocation as coming from the skill, so the `enforce-create-pr-skill` PreToolUse hook lets it through. Keep it on bare `gh pr create` calls; without it, the hook denies the command.

```bash
: __create-pr-skill__ ; gh pr create \
  --base <base> \
  --title "<title>" \
  --body "$(cat <<'EOF'
<body>
EOF
)" \
  [--draft if draft=true] \
  [--assignee <user> / --label <label> when the template's agent instructions request them]
```

**Existing PR** (found in Step 2; the initial check did not fetch the body to save tokens, so fetch it now if you need to inspect it before writing the update):

```bash
gh pr view <number> --json body --jq '.body'
```

Note the existing body may already contain a `<details><summary>Manual test plan</summary>…</details>` block; replace it with the new one rather than appending. Treat an existing agent-context section the same way: update its facts in place, preserving any human edits, rather than regenerating or dropping it.

```bash
gh pr edit <number> \
  --title "<title>" \
  --body "$(cat <<'EOF'
<body>
EOF
)" \
  [--add-assignee <user> / --add-label <label> when the template's agent instructions request them]
```

If `draft=true` and the existing PR is not already a draft:

```bash
gh pr ready --undo <number>
```

If `draft=false` and the existing PR is a draft:

```bash
gh pr ready <number>
```

### 10. Report Result

On success, display the PR URL. On failure, show the full error output and stop. Do not retry silently.
