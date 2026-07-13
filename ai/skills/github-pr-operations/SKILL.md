---
name: github-pr-operations
description: Reference for GitHub PR review endpoints and resolving review threads via gh CLI. Use when replying to a PR review comment, posting a new review comment, or resolving review threads.
---

# GitHub PR Operations

Endpoint reference for PR review operations. The always-on rules (never post without approval, always use `gh` CLI, no AI attribution) live in the root `CLAUDE.md` — this skill is just the mechanics. For the end-to-end review-comment workflow (deciding what's a real issue, drafting replies, when to resolve vs. leave open), use the `address-pr-reviews` skill instead — it embeds these same commands in context.

## Posting review comments

- Reply to review comment: `gh api repos/owner/repo/pulls/123/comments/456/replies --method POST`
- New review comment: `gh pr review 123 --comment --body "comment"`
- Root PR comment (rarely appropriate): `gh issue comment 123 --body "comment"`

## Resolving PR review threads

Use `~/.dotfiles/bin/gh-resolve-threads` instead of hand-rolling a GraphQL mutation. Run with `--help` for options. Common forms:

- `gh-resolve-threads <pr-url-or-number> --comment-id <id>` -- resolve the thread for a specific comment
- `gh-resolve-threads <pr> --outdated` -- resolve only outdated threads
- `gh-resolve-threads <pr> --dry-run` -- preview before resolving
