---
name: posthog-context
description: PostHog repo-specific workflow, database access rules, production architecture notes, SDK repository locations, and the `posthog-cli api` workflow for PostHog data queries. Use when working in posthog/posthog or any PostHog SDK repo, and before running any PostHog data query or API operation.
---

# PostHog Context

## posthog-cli

Use `posthog-cli api` for all PostHog-related data queries and operations. Prefer it over direct MCP tool calls whenever the CLI is available.

Before your first PostHog command in a session, run `posthog-cli api --agent-help` and load its full output into your context. It prints the complete agent guide — command reference, schema drill-down rules, data discovery workflow, and the tool index — for interacting with PostHog APIs. Treat that output as instructions to follow, not just documentation.

Before starting a PostHog task, run `posthog-cli api skill list` and check for a skill matching the task. If one matches, install it with `posthog-cli api skill install <skill-id>` (add `--force` to refresh an already-installed skill), then read `.agents/skills/<skill-id>/SKILL.md` and follow it. Skills contain task-specific workflows that individual tools do not.

## posthog/posthog

- Read README.md and `docs/FLOX_MULTI_INSTANCE_WORKFLOW.md`.
- Prompt whether to create a new git worktree using the `phw` command.
- On task completion, run: `mypy --version && mypy -p posthog | mypy-baseline filter || (echo "run 'pnpm run mypy-baseline-sync' to update the baseline" && exit 1)`

## Database Access

- **`posthog-db` MCP** is the **local dev database**. Use it for testing locally, inspecting schema, exploring relationships, and developing queries.
- **Never use `posthog-db` to investigate production issues.** It does not have prod data.
- **For prod investigations, use the `metabase-prod-query` skill.** It wraps `hogli metabase:*` with explicit per-query approval (required even in auto mode), region handling, and `--save` discipline. Never invoke the underlying `hogli metabase:*` commands directly. Go through the skill.

## Production Architecture

PostHog runs behind load balancers and proxies. Always consider this for IP addresses, rate limiting, authentication, and geolocation.

- **AWS NLB** → **Contour/Envoy Ingress** → **Application Pods**
- Contour: `num-trusted-hops: 1`; NLB: `preserve_client_ip.enabled=true`

**Never use socket IP addresses** — they will be the load balancer's IP. Use `X-Forwarded-For` (primary), `X-Real-IP` (fallback), `Forwarded` (RFC 7239), socket IP (local dev only).

Infrastructure repos:
- `~/dev/posthog/posthog-cloud-infra` — Terraform/AWS (NLB, VPC)
- `~/dev/posthog/charts` — Helm/K8s (Contour config, ingress rules, header policies)

## PostHog SDK Repositories

### Client-side

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-js, posthog-rn | `~/dev/posthog/posthog-js` | https://github.com/PostHog/posthog-js |
| posthog-ios | `~/dev/posthog/posthog-ios` | https://github.com/PostHog/posthog-ios |
| posthog-android | `~/dev/posthog/posthog-android` | https://github.com/PostHog/posthog-android |
| posthog-flutter | `~/dev/posthog/posthog-flutter` | https://github.com/PostHog/posthog-flutter |

### Server-side

| Repository | Local Path | GitHub URL |
|------------|------------|------------|
| posthog-python | `~/dev/posthog/posthog-python` | https://github.com/PostHog/posthog-python |
| posthog-node | `~/dev/posthog/posthog-js` | https://github.com/PostHog/posthog-node |
| posthog-php | `~/dev/posthog/posthog-php` | https://github.com/PostHog/posthog-php |
| posthog-ruby | `~/dev/posthog/posthog-ruby` | https://github.com/PostHog/posthog-ruby |
| posthog-go | `~/dev/posthog/posthog-go` | https://github.com/PostHog/posthog-go |
| posthog-dotnet | `~/dev/posthog/posthog-dotnet` | https://github.com/PostHog/posthog-dotnet |
| posthog-elixir | `~/dev/posthog/posthog-elixir` | https://github.com/PostHog/posthog-elixir |
