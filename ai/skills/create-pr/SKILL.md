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

Determine the base branch and gather context:

```bash
git rev-parse --abbrev-ref HEAD                                        # current branch
base=$(bash "$HOME/.dotfiles/bin/lib/git-default-branch.sh")           # base branch (bare name)
```

If the helper is not available or `base` is empty, tell the user and **stop**.

Then, using `$base`, run in parallel:

```bash
git log origin/$base..HEAD --oneline                    # commits on this branch
git diff origin/$base..HEAD                             # full diff vs base
gh pr view --json number,title,body,isDraft,url 2>/dev/null  # existing PR, if any
```

If a PR already exists, note its number and URL — you will **update** it rather than create a new one (see Step 5).

### 3. Find PR Template

Check these locations in order and stop at the first match:

1. `.github/pull_request_template.md`
2. `.github/PULL_REQUEST_TEMPLATE.md`
3. `.github/PULL_REQUEST_TEMPLATE/` — use `default.md` if it exists, otherwise the only file present; if multiple files with no clear default, ask the user which to use
4. `docs/pull_request_template.md`
5. `pull_request_template.md`

### 4. Compose Title and Body

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

If no template was found, write:

- 1–3 bullet points summarizing what the PR does (no customer-specific IDs or names)
- A short **Test plan** section describing how to verify the change

### 5. Show Preview and Confirm

If `force` is true, skip to Step 6 immediately — do not show a preview or ask for confirmation.

Otherwise, display the proposed PR to the user:

```text
Title: <title>
Draft: yes/no

<body>
```

Ask: "Create this PR? Reply yes to confirm, or describe any changes to make."

Wait for confirmation. If the user requests edits, apply them and show the updated preview before proceeding.

### 6. Ensure Branch Is Pushed

Before creating or updating the PR, verify the branch exists on the remote:

```bash
git push --set-upstream origin HEAD
```

If the push fails, report the error and stop.

### 7. Create or Update PR

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

**Existing PR** (found in Step 2):

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

### 8. Report Result

On success, display the PR URL. On failure, show the full error output and stop — do not retry silently.
