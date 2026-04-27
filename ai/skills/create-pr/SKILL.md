---
name: create-pr
description: Create or update a GitHub PR with automatic template detection and filling
argument-hint: "[--draft] [--force] [<title>]"
---

# Create PR

Create (or update) a GitHub pull request using `gh`, auto-detecting and filling any PR template.

## Arguments

- `--draft` — create the PR as a draft
- `--force` — skip preview and confirmation; create or update immediately
- `<title>` — optional title hint; if omitted, derive from commits

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
# 1. If a PR already exists, honor its base — never silently retarget it
existing_base=$(gh pr view --json baseRefName -q .baseRefName 2>/dev/null || true)

# 2. Ask gt for the parent (current gt stores stack metadata in
#    .git/.graphite_cache_persist, not in git config). The command exits
#    non-zero when gt isn't installed or the branch isn't tracked, so swallow
#    stderr and treat that as "no parent."
gt_parent=$(gt parent 2>/dev/null || true)

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
git log origin/$base..HEAD --oneline                    # commits on this branch
git diff origin/$base...HEAD                            # full diff vs base
gh pr view --json number,title,body,isDraft,url 2>/dev/null  # existing PR, if any
```

If a PR already exists, note its number and URL — you will **update** it rather than create a new one (see Step 8).

### 3. Find PR Template

Check these locations in order and stop at the first match:

1. `.github/pull_request_template.md`
2. `.github/PULL_REQUEST_TEMPLATE.md`
3. `.github/PULL_REQUEST_TEMPLATE/` — use `default.md` if it exists, otherwise the only file present; if multiple files with no clear default, ask the user which to use
4. `docs/pull_request_template.md`
5. `pull_request_template.md`

### 4. Detect Saved Test Plan

Check for a saved manual test plan (produced by `/test-plan`):

```bash
test_plan_path=".context/test-plan.md"
[ -f "$test_plan_path" ] && test_plan_content=$(cat "$test_plan_path")
```

If the file exists, hold its full contents for use in Step 5. If not, skip — the body composition step writes its own short test plan instead.

### 5. Compose Title and Body

**Title:**

- If `title_hint` is non-empty, use it as the title (trim and keep under 70 characters)
- Otherwise derive a short imperative title from the commits (e.g., "Add webhook retry support")

**Body:**

If a template was found, fill each section using the commits and diff:

- Describe final state — what the code does now, not what it replaced
- Remove unfilled optional sections rather than leaving placeholder text
- Leave checkboxes intact; check the ones clearly satisfied by the diff
- **Never include customer-specific data** — redact or omit any team IDs, team names, organization names, user IDs, or other identifying customer information found in commits or diffs; describe the fix generically instead (e.g., "fixes flag evaluation for teams with large cohorts" not "fixes team 12345 / Acme Corp")
- **Never uncomment, fill in, or add LLM/AI context sections** — if the template contains a commented-out LLM context section, leave it commented out or remove it entirely
- **Never hard-wrap prose** — write each paragraph as a single line and let GitHub's renderer handle wrapping; only insert newlines between paragraphs, list items, or headings

**PR description voice** — write the way an engineer talks, not the way an LLM writes:

- No significance inflation: avoid words like "critical", "pivotal", "essential", "robust", "comprehensive", "powerful", "seamless"
- No marketing phrasing and no "It's not just X, it's Y" patterns
- Use plain verbs: prefer "is" over "serves as" / "acts as" / "functions as"
- Avoid em-dashes; commas, colons, parentheses, and periods read more naturally
- Plain Sentence case headings, not Title Case
- No closers like "Hope this helps!" or "Let me know if you have any questions!"
- No emoji, and no bold for general emphasis (reserve bold for true labels)
- One concrete sentence beats a paragraph of hedging

If no template was found, write:

- 1–3 bullet points summarizing what the PR does (no customer-specific IDs or names)
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

- Strip a leading `## Test plan` (or equivalent) heading from the file contents before insertion — the surrounding section heading already provides that context
- Preserve the one-line `- [ ]` checkbox format exactly; do not re-wrap or reformat
- Keep the blank lines around `<details>` and `</details>` so GitHub renders the collapsible block correctly
- If the testing section already contains template guidance text (e.g., placeholders), replace that text with the `<details>` block rather than stacking them

### 6. Show Preview and Confirm

If `force` is true, skip to Step 7 immediately — do not show a preview or ask for confirmation.

Otherwise, display the proposed PR to the user. When `stacked=true`, include the base in the header so the non-default target is obvious:

```text
Title: <title>
Base: <base>            # only show this line when stacked=true; append " (stacked)"
Draft: yes/no

<body>
```

Ask: "Create this PR? Reply yes to confirm, or describe any changes to make."

Wait for confirmation. If the user requests edits, apply them and show the updated preview before proceeding.

### 7. Ensure Branch Is Pushed

When `stacked=true`, the parent branch must already exist on `origin` — GitHub can't open a PR against a base it doesn't have. Check first:

```bash
if [ "$stacked" = "true" ] && [ -z "$(git ls-remote --heads origin "$base")" ]; then
  echo "Parent branch '$base' is not on origin yet. Push it first (e.g. 'gt submit --stack' or 'git push origin $base') and re-run."
  exit 1
fi
```

Don't push the parent automatically — that's a stack-wide action and belongs to `gt`.

Then push HEAD:

```bash
git push --set-upstream origin HEAD
```

If the push fails, report the error and stop.

### 8. Create or Update PR

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

**Existing PR** (found in Step 2 — note the existing body may already contain a `<details><summary>Manual test plan</summary>…</details>` block; replace it with the new one rather than appending):

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

### 9. Report Result

On success, display the PR URL. On failure, show the full error output and stop — do not retry silently.
