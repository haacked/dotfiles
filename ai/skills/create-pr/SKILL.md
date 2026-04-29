---
name: create-pr
description: Create or update a GitHub PR with automatic template detection and filling
argument-hint: "[--draft] [--force] [<title>]"
---

# Create PR

Create (or update) a GitHub pull request using `gh`, auto-detecting and filling any PR template.

## Writing voice

Write the PR body the way a staff engineer writes a Slack message to a colleague who reviews the code. One direct sentence per idea. No ceremony.

Three things immediately signal AI authorship. Never produce any of them:

- Em dashes (—) or en dashes (–). Use a comma, colon, semicolon, parenthesis, or split into two sentences. No exceptions.
- Bold inside prose sentences. Bold is for labels at the start of a line only (e.g., `**Test plan:**`). Never bold error messages, key terms, or warnings mid-paragraph.
- Bolded pseudo-labels like `**Root cause:**`, `**Caveat:**`, `**Note:**`. Make it a real heading or fold the content into a sentence without a label.

For everything else: plain verbs ("is" not "serves as"), Sentence case headings, short paragraphs. No inflation words (critical, pivotal, robust, seamless, leverage, utilize, ensure, facilitate). No hedging meta-commentary ("I'm an agent", "I have not verified"). No closers. No emoji.

How it sounds:

> The workflow calls `getMembershipForUserInOrg()` with the default `GITHUB_TOKEN`, which only has repo scope and can't read org-private team memberships. The API returns `404` (not `403`) when it can't see the membership, producing the misleading error.
>
> If the app doesn't have Organization > Members > Read permission, the same error will recur.

Notice two things about that example: the cause and effect are in one sentence connected by a comma, and the caveat is a plain declarative sentence with no label.

## Arguments

- `--draft`: create the PR as a draft
- `--force`: skip preview and confirmation; create or update immediately
- `<title>`: optional title hint; if omitted, derive from commits

Example invocations:

- `/create-pr`
- `/create-pr --draft`
- `/create-pr --force`
- `/create-pr Add support for webhook retries`
- `/create-pr --draft Fix race condition in job queue`
- `/create-pr --force --draft Fix race condition in job queue`

## Steps

### 1. Parse Arguments

Extract from user input:

- `draft` = true if `--draft` is present
- `force` = true if `--force` is present
- `title_hint` = remaining text after stripping `--draft` and `--force`, or empty string

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
git log origin/$base..HEAD --oneline                                                   # commits on this branch
git diff origin/$base...HEAD                                                           # full diff vs base
gh pr list --head "$head" --state open --json number,title,body,isDraft,url --jq '.[0]'  # existing PR, if any
```

If a PR already exists, note its number and URL: you will **update** it rather than create a new one (see Step 9). Use `gh pr list --head` rather than `gh pr view`: it queries by branch name (reliable in worktrees and after re-clones) instead of relying on local upstream tracking.

### 3. Find PR Template

Check these locations in order and stop at the first match:

1. `.github/pull_request_template.md`
2. `.github/PULL_REQUEST_TEMPLATE.md`
3. `.github/PULL_REQUEST_TEMPLATE/`: use `default.md` if it exists, otherwise the only file present; if multiple files with no clear default, ask the user which to use
4. `docs/pull_request_template.md`
5. `pull_request_template.md`

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
- **Never uncomment, fill in, or add LLM/AI context sections.** If the template contains a commented-out LLM context section, leave it commented out or remove it entirely
- **Never hard-wrap prose.** Write each paragraph as a single line and let GitHub's renderer handle wrapping; only insert newlines between paragraphs, list items, or headings
- **Never escape backticks, dollar signs, or other markdown.** Step 9 passes the body through a quoted heredoc (`<<'EOF'`), which is literal; write `` `foo` `` not `` \`foo\` ``, and `$var` not `\$var`

**Voice.** Apply the writing voice from the `## Writing voice` section at the top of this skill throughout the body. The three hard rules (no em dashes, no bold inside prose, no bolded pseudo-labels) apply to every sentence you write here.

If no template was found, write:

- 1 to 3 bullet points summarizing what the PR does (no customer-specific IDs or names)
- A short **Test plan** section describing how to verify the change

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

Read the composed body once. If any sentence contains an em dash, bold text outside a line-start label, or a bolded pseudo-label, rewrite that sentence now. Then ask yourself: would a staff engineer write this sentence verbatim in a Slack message to a teammate? If not, simplify it.

### 7. Show Preview and Confirm

If `force` is true, skip to Step 8 immediately, do not show a preview or ask for confirmation.

Otherwise, display the proposed PR to the user. When `stacked=true`, include the base in the header so the non-default target is obvious:

```text
Title: <title>
Base: <base>            # only show this line when stacked=true; append " (stacked)"
Draft: yes/no

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

```bash
gh pr create \
  --base <base> \
  --title "<title>" \
  --body "$(cat <<'EOF'
<body>
EOF
)" \
  [--draft if draft=true]
```

**Existing PR** (found in Step 2; note the existing body may already contain a `<details><summary>Manual test plan</summary>…</details>` block, so replace it with the new one rather than appending):

```bash
gh pr edit <number> \
  --title "<title>" \
  --body "$(cat <<'EOF'
<body>
EOF
)"
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
