---
name: ops-report
description: Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus metrics. Produces a formatted markdown report with key metrics, anomalies, and recommendations.
model: sonnet
color: green
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, mcp__grafana__search_dashboards, mcp__grafana__get_dashboard_panel_queries, mcp__grafana__query_prometheus, mcp__grafana__query_prometheus_histogram, mcp__grafana__list_datasources, mcp__grafana__generate_deeplink, mcp__grafana__query_loki_logs, mcp__grafana__query_loki_stats, mcp__grafana__list_loki_label_names, mcp__grafana__list_loki_label_values
argument-hint: [service] [--hours N] [--region us|eu|dev]
---

# Ops Report

Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus/VictoriaMetrics metrics.

## Arguments (parsed from user input)

- **service** (optional): The service to report on (default: `feature-flags`). Other examples: `ingestion`, `capture`
- **--hours N** (optional): Lookback window in hours (default: 24)
- **--region** (optional): Grafana region to query: `us`, `eu`, or `dev` (default: `us`)

Example invocations:

- `/ops-report` - 24h report for feature flags (US, the default)
- `/ops-report feature-flags --hours 12` - 12h report
- `/ops-report ingestion --region eu` - Ingestion report from EU

## Your Task

Follow these steps in order.

### Step 1: Parse Arguments and Validate

Extract from user input:

- `service` - kebab-case service name, default "feature-flags"
- `hours` - lookback window, default 24
- `region` - default "us"

### Step 2: Discover Dashboards

Search Grafana for dashboards related to the service:

```text
mcp__grafana__search_dashboards(query="{service}")
```

Filter results to dashboards tagged with the service name or whose title contains the service name. Record each dashboard's UID, title, and description.

If no dashboards are found, tell the user and stop.

### Step 3: Discover Datasource

Find the Prometheus/VictoriaMetrics datasource:

```text
mcp__grafana__list_datasources(type="prometheus")
```

Use the default datasource (or the one named "VictoriaMetrics" if available). Record the `uid`.

### Step 4: Extract Key Queries from Dashboards

For the most important dashboards (the "general" or overview dashboard first, then latency, cache, and pods dashboards), extract panel queries:

```text
mcp__grafana__get_dashboard_panel_queries(uid="{dashboard_uid}")
```

Identify the key metrics to query. Prioritize these categories:

1. **Request rate** - throughput over time
2. **Success/error rate** - 2xx/3xx vs 5xx responses
3. **Latency** - P50, P95, P99 percentiles
4. **Resource usage** - CPU, memory relative to requests/limits
5. **Pod/scaling** - HPA replica count, pod restarts
6. **DB/cache performance** - pool utilization, cache hit rates, connection times
7. **Evaluation errors** - service-specific error counters

### Step 5: Query Metrics

Run PromQL queries against the datasource for each key metric category. Use range queries with appropriate step sizes:

- For the lookback window, use `now-{hours}h` to `now`
- Step size: use `300` seconds (5 min) for 24h windows, `60` seconds for shorter windows

Run queries in parallel where possible to minimize wall-clock time.

**Important:** Replace any `$__rate_interval` or `$__interval` template variables with appropriate values (e.g., `5m` for rate interval, `1m` for interval).

### Step 5b: Service-Specific Capacity Checks

For certain services, query additional capacity metrics that indicate approaching limits.

#### Feature Flags

Query the number of feature flags per team to identify teams nearing the maximum allowed count. Look for relevant metrics or dashboard panels that track:

- Total flag count per team/organization
- Teams approaching the configured maximum (e.g., >80% of the limit)
- Recent growth rate in flag creation

If a direct metric isn't available, check whether the dashboard panels show this data and note any teams that appear to be nearing capacity. Flag this as an action item if any team is above 80% of the maximum.

### Step 6: Analyze Results

For each metric time series, compute:

- **Current value** (most recent data point)
- **Min/max over the window**
- **Mean over the window**
- **Notable spikes or dips** (values more than 2x the mean, or sudden step changes)

Cross-correlate anomalies:

- Do error spikes correlate with latency spikes?
- Do latency spikes correlate with DB pool saturation?
- Do scaling events correlate with traffic surges?
- Are there any container restarts?
- Are any teams approaching resource or feature limits (e.g., max flag count)?

For each anomaly, attempt to investigate the cause by querying additional metrics, checking for correlated events, and noting what you ruled out. The goal is to hand the reader a partially-investigated issue with clear next steps, not just a raw signal.

### Step 7: Generate Dashboard Links

For each dashboard used, generate a deep link with the time range:

```text
mcp__grafana__generate_deeplink(
  resourceType="dashboard",
  dashboardUid="{uid}",
  timeRange={"from": "now-{hours}h", "to": "now"}
)
```

Replace `localhost:13000` in the generated URLs with the appropriate public Grafana hostname:

| Region | Hostname |
| ------ | -------- |
| us | `grafana.prod-us.posthog.dev` |
| eu | `grafana.prod-eu.posthog.dev` |
| dev | `grafana.dev.posthog.dev` |

### Step 8: Investigate Anomalies via Loki Logs

When anomalies are detected in Step 6 (e.g., 5xx error spikes, latency spikes), query Loki access logs to investigate root causes before writing the report. This transforms "check the logs" from a next step into an already-completed investigation.

#### Discover log structure

The Contour/Envoy access logs are in the `Loki-logs` datasource (uid: `P44D702D3E93867EC`). Key labels:

- `app="contour"` - Envoy access logs (NOT `app="envoy"`, which is sparse internal logs)
- `upstream_cluster` - The backend service, e.g., `posthog_posthog-feature-flags_3001`
- `response_code` - HTTP status code as a label (e.g., `"503"`, `"500"`)

Application logs use `app="posthog-feature-flags"` (or the service name).

#### Query 5xx errors

For each error spike detected in Prometheus metrics, query the actual access logs:

```text
mcp__grafana__query_loki_logs(
  datasourceUid="P44D702D3E93867EC",
  logql='{app="contour", response_code=~"5..", upstream_cluster="posthog_posthog-feature-flags_3001"}',
  startRfc3339="{spike_start}",
  endRfc3339="{spike_end}",
  limit=20
)
```

Analyze the `response_code_details` field to classify errors:

- `upstream_reset_before_response_started{connection_termination}` - Pod scaling / connection drops
- `via_upstream` - Application-level error (check the app logs)
- `response_timeout` - Upstream took too long

Also check `x_forwarded_host` to identify if errors are concentrated on a single customer proxy.

#### Query application logs

Check whether the application itself is logging errors:

```text
mcp__grafana__query_loki_logs(
  datasourceUid="P44D702D3E93867EC",
  logql='{app="posthog-feature-flags"} |~ "(?i)error"',
  startRfc3339="{spike_start}",
  endRfc3339="{spike_end}",
  limit=20
)
```

### Step 9: Write the Report

Determine today's date from the system. The report path is:

```text
~/dev/haacked/notes/PostHog/ops-reports/{YYYY-MM-DD}/{service}.md
```

If a report already exists at that path, tell the user and offer to overwrite it. Do not overwrite without confirmation.

Create the directory if it doesn't exist.

Use this structure for the report. The report leads with action items so the reader immediately knows what needs attention:

```markdown
# {Service Name} - {hours}-Hour Health Report

**Date:** {YYYY-MM-DD}
**Region:** {region description}
**Report window:** {start} to {end} UTC

## Overall Status: {Healthy | Degraded | Unhealthy}

{1-2 sentence executive summary}

## Action Items

{This section appears first so the reader immediately knows what needs attention. Each item should describe the anomaly, what investigation was already performed during report generation, and concrete next steps. If no action items exist, write "No action items. All metrics are within normal ranges."}

### {Priority}: {Action title}

- **What:** {Brief description of the anomaly or concern}
- **Evidence:** {Specific metric values, timestamps, and correlated signals}
- **Investigation so far:** {What was checked during report generation, e.g., "Correlated with deploy times - no deploys in this window" or "Error logs show timeout to downstream service X"}
- **Next steps:** {Concrete actions, e.g., "Check service X health", "Review recent deploy for regression", "Monitor for recurrence over next 24h"}

## Key Metrics Summary

| Metric | Current | {hours}h Range | Assessment |
| ------ | ------- | -------------- | ---------- |
| ... | ... | ... | ... |

## Anomalies and Notable Events

### 1. {Event title}

{Description with timestamps and correlated metrics}

## What's Working Well

- {Bullet points of positive signals}

## {Service-specific sections as appropriate}

{e.g., HPA Scaling Pattern, Cache Performance, DB Connection Pool, Capacity/Limits, etc.}

## Dashboard Links

These links require VPN access and Cognito authentication:

- [Dashboard Name](url)

## Data Sources

{Brief description of how the data was collected}
```

### Step 10: Lint and Confirm

Run markdownlint on the report if available:

```bash
npx markdownlint-cli {report_path} 2>&1 || true
```

Fix any lint errors. Then tell the user where the report was saved and offer a brief summary of the findings.

## Assessment Criteria

Use these thresholds to determine the overall status:

| Status | Criteria |
| ------ | -------- |
| **Healthy** | Success rate >99%, P99 <500ms, no sustained error spikes, no restarts |
| **Degraded** | Success rate 95-99%, P99 500ms-2s, brief error spikes, or scaling pressure |
| **Unhealthy** | Success rate <95%, P99 >2s, sustained errors, restarts, or pool exhaustion |

## Writing Style

- Be factual and specific with numbers and timestamps
- Distinguish between transient blips (single data points) and sustained issues
- Note boundary artifacts (e.g., `increase()` at query range boundaries producing inflated first values)
- Cross-reference metrics to establish causation, not just correlation
- Lead with action items; the reader should know within 10 seconds whether the report needs their attention
- For each action item, document what investigation was already performed and what remains
- Keep next steps actionable and tied to specific observations
- Use UTC timestamps throughout

## What You Do NOT Do

- Guess at metric values without querying
- Report on dashboards that don't exist for the service
- Create empty directories
- Use localhost URLs in the report
- Alarm on known benign patterns (e.g., diurnal traffic drops)
