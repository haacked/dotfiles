---
name: posthog-context
description: PostHog repo-specific workflow, database access rules, production architecture notes, and SDK repository locations. Use when working in posthog/posthog or any PostHog SDK repo.
---

# PostHog Context

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
