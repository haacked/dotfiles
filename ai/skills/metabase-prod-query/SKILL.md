---
name: metabase-prod-query
description: Query PostHog production Metabase for investigations. Use when the user wants to look at prod data (queries, counts, distributions, debugging customer reports, comparing regions). Wraps the `hogli metabase:*` commands (login, databases, query) into a guarded workflow that prompts for approval before running SQL against prod. Do NOT use for local dev investigations (use the `posthog-db` MCP for that).
argument-hint: "[--region us|eu|both] [<question or SQL>]"
model: sonnet
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Metabase Prod Query

Run SQL against PostHog production Metabase via `hogli metabase:*`. Production Metabase sits behind ALB Cognito OAuth, so this is the only path that works (API keys won't pass the ALB).

The four underlying commands:

| Command | Purpose |
| --- | --- |
| `hogli metabase:login --region us\|eu` | Opens browser, captures SSO cookies, caches at `~/.config/posthog/metabase/cookie-{region}` (mode 0600) |
| `hogli metabase:databases --region us\|eu` | Lists database IDs (these change when Metabase metadata is rebuilt — refresh per session) |
| `hogli metabase:query --region us\|eu --database-id N --file F.sql` | Runs SQL against `/api/dataset`; cookie stays internal |
| `hogli metabase:cookie --region us\|eu [--check]` | Prints cached cookie header (humans only — NEVER use this; `query` reads the cookie internally) |

## Non-negotiables

- **This hits prod.** Always show the SQL and get explicit user approval before running `metabase:query`. No exceptions.
- **Never run `metabase:cookie`.** That command prints credentials to the terminal/logs. The `query` command reads the cookie internally.
- **Use `--save PATH` for `query`.** Results can be large; dumping rows into the conversation transcript bloats context and risks leaking customer data. Save to a file, then read just what you need.
- **Refresh DB IDs every session.** They change when Metabase metadata is rebuilt. Run `metabase:databases` once at the start.
- **Never use this for local dev.** Local dev uses the `posthog-db` MCP. This skill is prod-only.

## Steps

### 1. Confirm scope

Parse args. Determine:

- **Region(s)**: `us`, `eu`, or `both`. If ambiguous, ask. (`both` means run sequentially per region.)
- **Question**: what is the user trying to learn? If they passed raw SQL, use it. If they passed a question, draft SQL in step 3.

If region or intent is unclear, ask the user before doing anything.

### 2. Verify session

For each region in scope, check the cookie cache:

```bash
test -f ~/.config/posthog/metabase/cookie-<region> && echo cached || echo missing
```

If missing, OR if a later command returns 301/302/401, run:

```bash
hogli metabase:login --region <region>
```

This opens the user's default browser. Tell the user this will happen before running it.

### 3. Refresh database IDs

Once per session per region:

```bash
hogli metabase:databases --region <region> --format json
```

Save the output. Note the relevant database IDs (typically `posthog` Postgres and `replica` ClickHouse, but verify by name — IDs are not stable across rebuilds). Pick the ID that matches the data the user is asking about (Postgres for app/control-plane data; ClickHouse for events/analytics).

### 4. Compose SQL

Write the query to a temp file under `/tmp/metabase-<short-slug>-<region>.sql`. Keep queries:

- **Bounded**: include `LIMIT` (e.g., `LIMIT 1000`) unless the user explicitly wants a full export.
- **Time-bounded**: include `WHERE timestamp >= now() - interval ...` (or equivalent) on event tables.
- **Read-only**: this is `SELECT`-only. Never write DDL/DML.

For ClickHouse-flavored questions, use ClickHouse SQL (no `interval '1 day'` Postgres syntax — use `INTERVAL 1 DAY`). For Postgres, use Postgres syntax.

### 5. Show SQL and get approval

Display to the user, exactly:

```
Region:      <us|eu|both>
Database:    <name> (id <N>)
Save to:     /tmp/metabase-<slug>-<region>.<tsv|json>

SQL:
  <the query, indented 2 spaces>
```

Then ask: "Run this query against prod? Reply yes to confirm, or describe changes."

Do not proceed until the user replies yes (or equivalent confirmation). If the user requests changes, update and re-show.

### 6. Run the query

```bash
hogli metabase:query \
  --region <region> \
  --database-id <id> \
  --file /tmp/metabase-<slug>-<region>.sql \
  --save /tmp/metabase-<slug>-<region>.tsv
```

For `--region both`, run once per region with separate `--save` paths.

Default format is TSV. Pass `--format json` only when the user needs structured output.

### 7. Read and summarize results

Read the saved file with `Read` (or `head`/`wc -l` for size first). Report to the user:

- Row count
- Top N rows (or summary stats — sums, distributions — depending on the question)
- Anomalies worth flagging

Do not paste the full result file into the chat unless the user asks for it.

### 8. Clean up (optional)

If the saved files contain potentially sensitive data and the user is done, offer to delete them:

```bash
rm /tmp/metabase-<slug>-*.{sql,tsv,json}
```

## Error handling

| Symptom | Cause | Fix |
| --- | --- | --- |
| 301/302 redirect | Cookie expired or ALB session lost | Re-run `metabase:login --region <region>` |
| 401 Unauthorized | Cookie rejected | Re-run `metabase:login --region <region>` |
| 404 on database-id | DB IDs changed | Re-run `metabase:databases --region <region>` |
| `Query failed: ...` in body | SQL error | Read the error, fix SQL, re-show for approval, re-run |
| Non-JSON response | Upstream issue | Show the raw response to the user; do not retry blindly |

## Notes

- The cookie cache file is mode `0600` and lives at `~/.config/posthog/metabase/cookie-{region}`. Do not `cat` it, copy it elsewhere, or print its contents.
- The two production hosts are `metabase.prod-us.posthog.dev` and `metabase.prod-eu.posthog.dev`. You don't need to use them directly — `hogli` handles routing.
- For long-running queries, pass `--timeout <seconds>` (default 120s).
