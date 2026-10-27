---
name: usage-all
description: Show plan usage and limit reset times for every signed-in Claude account at once, the way /usage shows them for the current account, plus which accounts docket and /go run reviews on and which one the next review uses. Covers the default login, each ~/.claude-* config directory, and each account in docket's config.toml. Use when the user asks how much usage is left across their accounts, which account has room, when limits reset, which account docket or /go is using, or runs /usage-all.
argument-hint: "[config-dir…]"
compatibility: Designed for Claude Code (or similar products)
model: haiku
metadata:
  execution-tier: fast
---

# /usage-all

Answers two questions: how much of each Claude account's limits is used and when does each limit reset, and which account do docket and /go review on?

## Steps

1. Run the report, passing any config directories the user named:

   ```bash
   scripts/claude-usage [config-dir…]
   ```

   With no arguments it reads the default login, every `~/.claude-*` directory that has signed in, and every account in docket's `config.toml`. Directories signed in to the same login (one account in one organization) share its limits, so the report shows them as one account and lists every directory on its account line. An access token that expired gets refreshed through `claude mcp get`, which takes about a second per directory.

   The report ends with the lines that `run-review.py accounts` from the go skill gives: docket's rotation, the account the next review runs on, and each directory that docket and /go skip until a usage limit that docket recorded resets. A recorded limit applies to every directory signed in to the same login. /go follows the same rotation as docket, and also falls back to the account of the session that runs it.

2. Lead with one line that names each account at 100% of its session or weekly limit and when that limit resets, then the account that the next review runs on. When no account is at a limit, name the account with the most room in its session and weekly limits.

   The `Extra usage` row is not a limit, and it has no reset time. Extra usage pays for requests only after a session or weekly limit reaches 100%, so an account at 100% extra usage still serves requests while its session and weekly limits have room. Mention extra usage only for an account at a session or weekly limit: when its extra usage is also at 100% or off, claude refuses that account's requests until the limit resets.

3. Show the report verbatim in a fenced code block. Do not reformat it into a Markdown table, because the bars and the column alignment only line up in a monospace block.

4. When an account shows a `✗` line, repeat its fix after the block, such as running `CLAUDE_CONFIG_DIR=~/.claude-automation claude` and `/login`.

`scripts/claude-usage --json` prints `{accounts, reviews}` when a question needs a field that the report leaves out. Each entry of `accounts` holds the account's `dirs`, each with its `error`, and the raw `/api/oauth/usage` response, with fields such as `seven_day_breakdown`. `reviews` holds docket's `rotation`, the `order` a review tries the accounts in, and the `limits` that docket recorded and that still apply.
