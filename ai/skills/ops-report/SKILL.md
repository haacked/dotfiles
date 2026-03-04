---
name: ops-report
description: Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus metrics. Produces a formatted markdown report with key metrics, anomalies, and recommendations.
model: sonnet
color: green
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, mcp__grafana__search_dashboards, mcp__grafana__get_dashboard_panel_queries, mcp__grafana__query_prometheus, mcp__grafana__query_prometheus_histogram, mcp__grafana__list_datasources, mcp__grafana__generate_deeplink, mcp__grafana__query_loki_logs, mcp__grafana__query_loki_stats, mcp__grafana__list_loki_label_names, mcp__grafana__list_loki_label_values
argument-hint: [service] [--window day|week|month] [--region us|eu|dev]
---

# Ops Report

Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus/VictoriaMetrics metrics.

## Arguments (parsed from user input)

- **service** (optional): The service to report on (default: `feature-flags`). Other examples: `ingestion`, `capture`
- **--window** (optional): Lookback window: `day` (24h), `week` (7d), or `month` (30d). Default: `day`
- **--region** (optional): Grafana region to query: `us`, `eu`, or `dev` (default: `us`)

Example invocations:

- `/ops-report` - daily report for feature flags (US, the default)
- `/ops-report feature-flags --window week` - weekly report
- `/ops-report ingestion --region eu` - daily ingestion report from EU

## Your Task

Follow these steps in order.

### Step 1: Parse Arguments and Validate

Extract from user input:

- `service` - kebab-case service name, default "feature-flags"
- `window` - one of `day`, `week`, `month`. Default "day"
- `region` - default "us"

Map the window to query parameters:

| Window | Hours | PromQL Step | Loki query range per anomaly |
| ------ | ----- | ----------- | ---------------------------- |
| day | 24 | 300s (5min) | narrow (spike +/- 15min) |
| week | 168 | 1800s (30min) | wider (spike +/- 1h) |
| month | 720 | 7200s (2h) | widest (spike +/- 4h) |

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

Run PromQL queries against the datasource for each key metric category. Use range queries with the step size from the window table above:

- For the lookback window, use `now-{hours}h` to `now`
- Step size: use the value from the window mapping (300s for day, 1800s for week, 7200s for month)

Run queries in parallel where possible to minimize wall-clock time.

**Important:** Replace any `$__rate_interval` or `$__interval` template variables with appropriate values. For `day` use `5m`/`1m`, for `week` use `30m`/`5m`, for `month` use `2h`/`30m`.

### Step 5b: Service-Specific Capacity Checks

For certain services, query additional capacity metrics that indicate approaching limits.

#### Feature Flags

Query the number of feature flags per team to identify teams nearing the maximum allowed count. Look for relevant metrics or dashboard panels that track:

- Total flag count per team/organization
- Teams approaching the configured maximum (e.g., >80% of the limit)
- Recent growth rate in flag creation

If a direct metric isn't available, check whether the dashboard panels show this data and note any teams that appear to be nearing capacity. Flag this as an action item if any team is above 80% of the maximum.

#### Scheduled Task Performance

Query scheduled Celery task duration and verification fix counts from the cache dashboard. These tasks run periodically to maintain cache consistency.

**Task duration** (average per run, sampled over the window):

```promql
increase(posthog_celery_task_duration_seconds_sum{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\.(refresh_expiring_flags_cache_entries|cleanup_stale_flags_expiry_tracking_task)|posthog\\.tasks\\.team_metadata\\.(refresh_expiring_team_metadata_cache_entries|cleanup_stale_expiry_tracking_task)|posthog\\.tasks\\.team_access_cache_tasks\\.warm_all_team_access_caches_task"}[$__rate_interval])
/
increase(posthog_celery_task_duration_seconds_count{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\.(refresh_expiring_flags_cache_entries|cleanup_stale_flags_expiry_tracking_task)|posthog\\.tasks\\.team_metadata\\.(refresh_expiring_team_metadata_cache_entries|cleanup_stale_expiry_tracking_task)|posthog\\.tasks\\.team_access_cache_tasks\\.warm_all_team_access_caches_task"}[$__rate_interval])
```

Replace `$__rate_interval` per the window mapping. Query this as a range query to get a time series, then compute min, max, and average duration across the window for each `task_name`. Convert seconds to human-readable format (e.g., `~690s (11.5 min)`).

**Verification fix counts** (total fixes applied over the window):

```promql
sum by(cache_type, issue_type) (increase(posthog_hypercache_verify_fixes_total[{window_hours}h]))
```

This tracks how many cache inconsistencies the verification tasks detected and fixed. Group by `cache_type` (e.g., `feature_flags`, `team_metadata`) and `issue_type` (e.g., `cache_mismatch`, `missing_entry`). A non-zero count is not necessarily alarming (self-healing is working), but sustained high counts or a sudden increase warrants investigation.

**Task failure counts** (over the window):

```promql
sum by(task_name) (increase(posthog_celery_task_failure_total{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\..*|posthog\\.tasks\\.team_metadata\\..*"}[{window_hours}h]))
```

Any task failures should be flagged as an action item.

**Task execution count** (total runs over the window, reuses the duration count metric):

```promql
sum by(task_name) (increase(posthog_celery_task_duration_seconds_count{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\.(refresh_expiring_flags_cache_entries|cleanup_stale_flags_expiry_tracking_task)|posthog\\.tasks\\.team_metadata\\.(refresh_expiring_team_metadata_cache_entries|cleanup_stale_expiry_tracking_task)|posthog\\.tasks\\.team_access_cache_tasks\\.warm_all_team_access_caches_task"}[{window_hours}h]))
```

This gives the total number of executions per task in the window. Include this as the "Runs" column in the scheduled tasks table to contextualize duration statistics.

**Task retry counts** (retries over the window):

```promql
sum by(task_name) (increase(posthog_celery_task_retry_total{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\..*|posthog\\.tasks\\.team_metadata\\..*"}[{window_hours}h]))
```

Retries are typically zero. Only include them in the report when non-zero, rendered as a footnote beneath the scheduled tasks table rather than a dedicated column.

**Queue health** (queue depth stats and trend for feature flag queues):

Average depth over the window:

```promql
avg_over_time(posthog_celery_queue_depth{queue=~"feature_flags|feature_flags_long_running"}[{window_hours}h])
```

Maximum depth over the window:

```promql
max_over_time(posthog_celery_queue_depth{queue=~"feature_flags|feature_flags_long_running"}[{window_hours}h])
```

Trend (positive = growing, negative = draining, near-zero = stable):

```promql
deriv(posthog_celery_queue_depth{queue=~"feature_flags|feature_flags_long_running"}[{window_hours}h])
```

Classify the trend: `deriv > 0.1` = "Growing", `deriv < -0.1` = "Draining", otherwise "Stable". Queue depth is a queue-level metric, not per-task, so render it as a separate sub-section after the scheduled tasks table.

**Batch refresh coverage** (teams processed by the hourly batch refresh):

```promql
posthog_hypercache_teams_processed_last_run{namespace=~"feature_flags|team_metadata"}
```

Query this as an instant query. It shows how many teams the most recent batch refresh processed, broken down by `namespace` and `status` (success/failure). If any failures are present, flag them as an action item.

**Fallback guidance:** If any of these metrics return no data, omit that section from the report rather than reporting zeros.

#### HPA Scaling Efficiency

Query these three metrics to assess whether the HPA is tuned correctly.

**% time at max replicas** (fraction of the window where desired replicas hit the max):

```promql
count_over_time((kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="posthog-feature-flags"} >= kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler="posthog-feature-flags"})[{window_hours}h:5m])
/ count_over_time(kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="posthog-feature-flags"}[{window_hours}h:5m])
```

**CPU headroom ratio** (range query — how close the hottest pod is to the HPA target):

```promql
max(sum by (pod)(rate(container_cpu_usage_seconds_total{namespace="posthog", container="posthog-feature-flags"}[5m])) / on(pod) sum by (pod)(kube_pod_container_resource_requests{resource="cpu", namespace="posthog", container="posthog-feature-flags"})) / 0.70
```

**Scaling events** (number of HPA replica changes in the window):

```promql
changes(kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="posthog-feature-flags"}[{window_hours}h])
```

**Interpretation thresholds:**

- % at max > 20% → action item (raise maxPods or lower CPU target)
- Headroom ratio peak > 0.9 → HPA being pushed close to scaling
- Headroom ratio peak < 0.5 → CPU target may be too conservative

**Fallback:** If any of these metrics return no data, omit the HPA Scaling Efficiency section from the report.

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
- Is the HPA spending >20% of the window at max replicas? Does headroom correlate with latency?
- Are there any container restarts?
- Are any teams approaching resource or feature limits (e.g., max flag count)?
- Do task duration increases correlate with queue depth growth?
- Are batch refresh failures correlated with worker OOM kills?

For each anomaly, attempt to investigate the cause by querying additional metrics, checking for correlated events, and noting what you ruled out. The goal is to hand the reader a partially-investigated issue with clear next steps, not just a raw signal.

### Step 7: Generate Dashboard Links

For each dashboard used, generate a deep link with the time range:

```text
mcp__grafana__generate_deeplink(
  resourceType="dashboard",
  dashboardUid="{uid}",
  timeRange={"from": "now-{window_hours}h", "to": "now"}
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
~/dev/haacked/notes/PostHog/ops-reports/{YYYY-MM-DD}/{service}-{window}.md
```

For `day` window, the filename can omit the suffix (e.g., `feature-flags.md`). For `week` and `month`, include it (e.g., `feature-flags-week.md`).

If a report already exists at that path, tell the user and offer to overwrite it. Do not overwrite without confirmation.

Create the directory if it doesn't exist.

Use this structure for the report. The report leads with action items so the reader immediately knows what needs attention:

```markdown
# {Service Name} - {Window Label} Health Report

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

| Metric | Current | Range | Assessment |
| ------ | ------- | ----- | ---------- |
| ... | ... | ... | ... |

## Anomalies and Notable Events

### 1. {Event title}

{Description with timestamps and correlated metrics}

## What's Working Well

- {Bullet points of positive signals}

## Scheduled Tasks

| Task | Runs | Min | Max | Avg | Fixes ({window}) |
|------|------|-----|-----|-----|------------------|
| `task_short_name` | N | ~11.5 min | ~12.1 min | ~11.8 min | 0 |

{Use the short task name (e.g., `verify_and_fix_flags_cache_task`) rather than the full dotted path. For durations, use `~Xs` for values under 60s and `~Y.Z min` for values over 60s. For the Fixes column, show the total count and bold it if non-zero, appending the issue types in parentheses (e.g., **3** (cache_mismatch)). If a task had failures, note them in a row below or as a footnote. Omit tasks that had zero runs in the window. If any tasks had retries during the window, annotate the task name with an asterisk and add a footnote below the table (e.g., `*3 retries during the window`). Omit the footnote entirely when all retry counts are zero.}

### Queue Health

| Queue | Avg Depth | Max Depth | Trend |
|-------|-----------|-----------|-------|
| `feature_flags` | N | N | Stable/Growing/Draining |
| `feature_flags_long_running` | N | N | Stable/Growing/Draining |

{Show average and maximum queue depth over the window, plus the trend derived from `deriv()`. Classify trend as "Growing" (deriv > 0.1), "Draining" (deriv < -0.1), or "Stable" (near zero). A growing queue paired with increasing task durations warrants investigation. Omit this section if queue depth metrics return no data.}

### Batch Refresh Coverage

{One-line summary of `posthog_hypercache_teams_processed_last_run` results, e.g., "Batch refresh processed N teams (feature_flags) and M teams (team_metadata) with no failures." If any failures are present, bold the failure count and flag as an action item. Omit this section if the metric returns no data.}

## HPA Scaling Efficiency

| Metric | Value | Assessment |
|--------|-------|------------|
| Time at max replicas | X% | OK / Elevated / Critical |
| CPU headroom (max pod / target) | X.XX avg, X.XX peak | Comfortable / Tight / Over-target |
| Scaling events | N | Stable / Moderate / Volatile |

## {Service-specific sections as appropriate}

{e.g., Cache Performance, DB Connection Pool, Capacity/Limits, etc.}

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
