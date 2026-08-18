---
name: ops-report
description: Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus metrics. Produces a formatted markdown report with key metrics, anomalies, and recommendations.
model: sonnet
color: green
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, mcp__grafana__search_dashboards, mcp__grafana__get_dashboard_panel_queries, mcp__grafana__query_prometheus, mcp__grafana__query_prometheus_histogram, mcp__grafana__list_datasources, mcp__grafana__generate_deeplink, mcp__grafana__query_loki_logs, mcp__grafana__query_loki_stats, mcp__grafana__list_loki_label_names, mcp__grafana__list_loki_label_values, mcp__grafana-eu__search_dashboards, mcp__grafana-eu__get_dashboard_panel_queries, mcp__grafana-eu__query_prometheus, mcp__grafana-eu__query_prometheus_histogram, mcp__grafana-eu__list_datasources, mcp__grafana-eu__generate_deeplink, mcp__grafana-eu__query_loki_logs, mcp__grafana-eu__query_loki_stats, mcp__grafana-eu__list_loki_label_names, mcp__grafana-eu__list_loki_label_values
argument-hint: "[service] [--window day|week|month] [--region us|eu|both]"
---

# Ops Report

Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus/VictoriaMetrics metrics.

## Arguments (parsed from user input)

- **service** (optional): The service to report on (default: `feature-flags`). Other examples: `ingestion`, `capture`
- **--window** (optional): Lookback window: `day` (24h), `week` (7d), or `month` (30d). Default: `day`
- **--region** (optional): Grafana region to query: `us`, `eu`, or `both` (default: `both`)

Example invocations:

- `/ops-report` - daily report for feature flags (both regions, the default)
- `/ops-report feature-flags --window week` - weekly report for both regions
- `/ops-report ingestion --region eu` - daily ingestion report from EU only
- `/ops-report --region us` - US-only report

## MCP Server Mapping

| Region | MCP Server | Public Hostname |
| ------ | ---------- | --------------- |
| us | `mcp__grafana__*` | `grafana.prod-us.posthog.dev` |
| eu | `mcp__grafana-eu__*` | `grafana.prod-eu.posthog.dev` |

**Regional parallelism:** wherever a step says "for each active region", fire the region-specific MCP calls in parallel. Query examples in this skill show the US form only; for EU, use the `mcp__grafana-eu__*` equivalent with the EU datasource UID. Tag every metric, anomaly, and dashboard link with its region (`[US]` / `[EU]`) throughout.

## Your Task

Follow these steps in order.

### Step 1: Parse Arguments and Validate

Extract from user input:

- `service` - kebab-case service name, default "feature-flags"
- `window` - one of `day`, `week`, `month`. Default "day"
- `region` - one of `us`, `eu`, `both`. Default "both"

Determine which MCP servers to use:

- `region=us` → `mcp__grafana__*` only
- `region=eu` → `mcp__grafana-eu__*` only
- `region=both` → both `mcp__grafana__*` and `mcp__grafana-eu__*` in parallel

Map the window to query parameters:

| Window | Hours | PromQL Step | Loki query range per anomaly |
| ------ | ----- | ----------- | ---------------------------- |
| day | 24 | 300s (5min) | narrow (spike +/- 15min) |
| week | 168 | 1800s (30min) | wider (spike +/- 1h) |
| month | 720 | 7200s (2h) | widest (spike +/- 4h) |

Compute absolute UTC timestamps for the report window. All Prometheus and Loki queries must use these absolute timestamps; never use relative expressions like `now-24h`. Absolute timestamps ensure that spike times read from Prometheus responses correspond exactly to the report window, so Loki follow-up queries target the correct time.

For a `day` report generated on date D, the window is:

```text
window_start = {D - 1 day}T00:00:00Z   (e.g. 2026-03-17T00:00:00Z)
window_end   = {D}T00:00:00Z            (e.g. 2026-03-18T00:00:00Z)
```

For `week` and `month`, anchor the window end to `{D}T00:00:00Z` and subtract accordingly:

```text
week:  window_start = {D - 7 days}T00:00:00Z  (e.g. 2026-03-11T00:00:00Z)
month: window_start = {D - 30 days}T00:00:00Z (e.g. 2026-02-16T00:00:00Z)
```

Record these values:

- `{window_start}` and `{window_end}`: absolute RFC3339 timestamps for all query `start`/`end` parameters
- `{window_hours}`: 24, 168, or 720, for use in PromQL range selectors like `[{window_hours}h]`

State the computed `{window_start}`, `{window_end}`, and `{window_hours}` values before proceeding to Step 2.

Record the current session JSONL line count for token tracking:

```bash
claude-session-tokens --line-count
```

Store the output plus one as `{token_baseline_line}` (i.e., `line_count + 1`) so that `--sum-from` starts after the last pre-existing line.

### Step 2: Discover Dashboards

Search Grafana for dashboards related to the service, for each active region:

```text
mcp__grafana__search_dashboards(query="{service}")
```

Filter results to dashboards tagged with the service name or whose title contains the service name. Record each dashboard's UID, title, description, and region. Dashboard UIDs are often the same across regions; query both independently.

If no dashboards are found in either region, tell the user and stop.

### Step 3: Discover Datasources

For each active region, discover the Prometheus datasources and the Loki datasources (needed for log queries in Step 8):

```text
mcp__grafana__list_datasources(type="prometheus")
mcp__grafana__list_datasources(type="loki")
```

For each region, use the datasource named "VictoriaMetrics" (or the default Prometheus datasource). Record each region's Prometheus UID and Loki UID separately. Do not hardcode UIDs; discover them here.

The US Loki datasource is typically named `Loki-logs` (uid `P44D702D3E93867EC`), but always verify via discovery rather than assuming.

### Step 4: Extract Key Queries from Dashboards

For the most important dashboards (the "general" or overview dashboard first, then latency, cache, and pods dashboards), extract panel queries for each active region:

```text
mcp__grafana__get_dashboard_panel_queries(uid="{dashboard_uid}")
```

If dashboards share the same UID across regions, the panel structure will be identical, so you only need to extract queries once and reuse them for both regions' metric queries in Step 5.

Identify the key metrics to query. Prioritize these categories:

1. **Request rate** - throughput over time
2. **Success/error rate** - 2xx/3xx vs 5xx responses
3. **Latency** - P50, P95, P99 percentiles
4. **Resource usage** - CPU, memory relative to requests/limits
5. **Pod/scaling** - HPA replica count, pod restarts
6. **DB/cache performance** - pool utilization, cache hit rates, connection times
7. **Evaluation errors** - service-specific error counters

### Step 5: Query Metrics

Run PromQL range queries against each active region's Prometheus datasource, storing results separately per region so they can be compared in the report:

- Use the absolute `{window_start}` and `{window_end}` timestamps computed in Step 1 as the query `startTime`/`endTime` parameters, never `now-{hours}h` or `now`
- Step size: use the value from the window mapping (300s for day, 1800s for week, 7200s for month)

**Note:** The ban on relative expressions applies to the query's `startTime`/`endTime` parameters. PromQL duration expressions *inside* the query (range selectors like `[5m]`, `[{window_hours}h]`, and subquery windows) remain as durations. These are lookback windows within PromQL, not the time range of the query itself.

**Important:** Replace any `$__rate_interval` or `$__interval` template variables with appropriate values. For `day` use `5m`/`1m`, for `week` use `30m`/`5m`, for `month` use `2h`/`30m`.

### Step 5b: Service-Specific Capacity Checks

Read `~/.claude/skills/ops-report/references/capacity-checks.md` and run the checks that apply to the service, for each active region. Currently all checks target `feature-flags`; skip this step if the file has no entries for the service.

### Step 6: Analyze Results

For each metric time series, compute:

- **Current value** (most recent data point)
- **Min/max over the window**
- **Mean over the window**
- **Notable spikes or dips** (values more than 2x the mean, or sudden step changes)

**All timestamps reported must come directly from Prometheus data point values, never from log entries, correlated signals, or inference.** A log message at time T is not evidence that a metric spike occurred at time T. For each detected spike, record its peak as `{spike_peak_utc}` (the exact timestamp from the Prometheus data point) for use in Step 8.

#### Error Spike Count

After querying the 5xx error count time series, compute a spike count:

1. Count the number of data points where 5xx errors exceeded the warning threshold (thresholds apply per data point regardless of step size)
2. Classify each spike by severity:
   - **Warning**: 50–299 errors per data point
   - **Critical**: ≥ 300 errors per data point
3. Record the timestamps of the worst spikes for investigation in Step 8

Use the same spike count assessment labels as the Latency Spike Count table below.

#### Latency Spike Count

After querying the P99 latency time series, compute a spike count:

1. Compute the **median** of all P99 data points in the window
2. Set the spike threshold to **max(2 × median, 200ms)**
3. Count the number of sampling intervals where P99 exceeded the threshold
4. Classify each spike by severity:
   - **Minor**: threshold < P99 ≤ 300ms
   - **Warning**: 300ms < P99 ≤ 600ms
   - **Critical**: P99 > 600ms
5. Record the timestamps of the worst spikes for investigation in Step 8

Use these labels for the spike count assessment:

| Window | None | Occasional | Elevated | Frequent |
| ------ | ---- | ---------- | -------- | -------- |
| day | 0 | 1–3 | 4–10 | >10 |
| week | 0 | 1–10 | 11–30 | >30 |
| month | 0 | 1–30 | 31–90 | >90 |

Cross-correlate anomalies:

- Do error spikes correlate with latency spikes?
- Do latency spikes correlate with DB pool saturation?
- Do latency spikes cluster at specific times of day (e.g., peak traffic hours)?
- Do latency spikes correlate with DB pool utilization spikes?
- Do scaling events correlate with traffic surges?
- Is the HPA spending >20% of the window at max replicas? Does headroom correlate with latency?
- Are there any container restarts?
- Are any teams approaching resource or feature limits (e.g., max flag count)?
- Do task duration increases correlate with queue depth growth?
- Are batch refresh failures correlated with worker OOM kills?
- Do `sync_feature_flag_last_called` success rate drops correlate with worker log errors?
- Do billing aggregator flush errors or stale-flush alarms correlate with Redis latency or `flag_request_redis_error` spikes? Does pending queue growth precede `unflushed_requests_total{cause="cap_drop"}`?

For each anomaly, attempt to investigate the cause by querying additional metrics, checking for correlated events, and noting what you ruled out. The goal is to hand the reader a partially-investigated issue with clear next steps, not just a raw signal.

### Step 7: Generate Dashboard Links

For each dashboard used, generate deep links with the time range for each active region. Dashboard links use relative time ranges (`now-{window_hours}h`) so they open correctly in the browser. This is the only place relative expressions are used:

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

Query each region where an anomaly was detected using that region's Loki datasource UID (discovered in Step 3, not hardcoded).

**Use `{spike_peak_utc}` from Step 6 (the actual Prometheus data point timestamp) as the centre of the Loki query window.** Never substitute a time from a log message or a guess. The goal is to look at logs *at the moment the metric spike occurred*, not at the moment of a correlated (but possibly unrelated) log entry. Set `{spike_start}` = `{spike_peak_utc}` − 15 min and `{spike_end}` = `{spike_peak_utc}` + 15 min (or wider for week/month windows).

#### Discover log structure

The Contour/Envoy access logs are in each region's `Loki-logs` datasource (use the UID discovered in Step 3). Key labels:

- `app="contour"` - Envoy access logs (NOT `app="envoy"`, which is sparse internal logs)
- `upstream_cluster` - The backend service, e.g., `posthog_posthog-feature-flags_3001`
- `response_code` - HTTP status code as a label (e.g., `"503"`, `"500"`)

Application logs use `app="posthog-feature-flags"` (or the service name).

#### Query 5xx errors

For each error spike, query the access logs in the affected region:

```text
mcp__grafana__query_loki_logs(
  datasourceUid="{loki_uid}",
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

Check whether the application itself is logging errors for each affected region:

```text
mcp__grafana__query_loki_logs(
  datasourceUid="{loki_uid}",
  logql='{app="posthog-feature-flags"} |~ "(?i)error"',
  startRfc3339="{spike_start}",
  endRfc3339="{spike_end}",
  limit=20
)
```

#### Broad log scan for warnings and errors (full window)

Regardless of whether anomalies were detected in Step 6, scan the application logs across the **entire reporting window** for warnings and errors, for each active region:

```text
# errors
mcp__grafana__query_loki_logs(
  datasourceUid="{loki_uid}",
  logql='{app="{service}"} | json | level =~ "(?i)(error|err)"',
  startRfc3339="{window_start}",
  endRfc3339="{window_end}",
  limit=50
)

# warnings
mcp__grafana__query_loki_logs(
  datasourceUid="{loki_uid}",
  logql='{app="{service}"} | json | level =~ "(?i)(warn|warning)"',
  startRfc3339="{window_start}",
  endRfc3339="{window_end}",
  limit=50
)
```

If the `json` parser doesn't match (service uses unstructured logs), fall back to pattern matching:

```text
logql='{app="{service}"} |~ "(?i)(error|err[^o])"'
logql='{app="{service}"} |~ "(?i)(warn|warning)"'
```

For each region, group the results by message pattern (strip timestamps, request IDs, and other variable fields) and count occurrences. Identify the **top 5 most frequent** warning patterns and **top 5 most frequent** error patterns. Note whether any patterns are new compared to what would be expected background noise.

**Deduplication:** If a log pattern from a spike-anchored query is already covered in the Anomalies section, do not repeat it in Warning and Error Logs. Cross-reference instead.

**Sub-threshold errors:** If the broad log scan finds 5xx errors but no Prometheus spike crossed the warning threshold (50 per data point), report the log errors under Warning and Error Logs but do not create an error spike anomaly or action item.

#### Worker task logs

Regardless of whether anomalies were detected, scan the worker logs across the **entire reporting window** for errors and warnings related to the service being reported on. Use the same query pattern as the broad log scan above, but with two changes:

- **App label:** `{app="posthog-worker-django"}` instead of `{app="{service}"}`
- **Line filter:** Add `|= "{service_keyword}"` to scope results to the service, where `service_keyword` is derived from `service` by lowercasing and replacing hyphens with underscores (e.g., `feature-flags` → `feature_flags`, `ingestion` → `ingestion`)

Run errors and warnings for each active region, with `limit=50`, using the same `{window_start}`/`{window_end}` range. Apply the same `json` parser with level filter, and the same unstructured-log fallback pattern if `json` doesn't match.

Group results by message pattern and identify the **top 5 most frequent** error and warning patterns, same as the broad scan. Deduplicate against the `{app="{service}"}` scan: if a pattern already appeared there, do not repeat it. Cross-reference worker error patterns with the `sync_feature_flag_last_called` success rate from Step 5b; if error logs correlate with a low success rate, note the correlation.

### Step 9: Write the Report

Determine today's date from the system. The report path is:

```text
~/dev/haacked/notes/PostHog/raw/ops-reports/{YYYY-MM-DD}/{service}-{window}.md
```

For `day` window, the filename can omit the suffix (e.g., `feature-flags.md`). For `week` and `month`, include it (e.g., `feature-flags-week.md`).

If a report already exists at that path, tell the user and offer to overwrite it. Do not overwrite without confirmation.

Read `~/.claude/skills/ops-report/templates/report-template.md` and follow its structure. Braced text in the template is authoring instruction, not literal content. The report leads with action items so the reader immediately knows what needs attention.

### Step 10: Token Usage, Lint, and Confirm

#### Token Usage

Query the token usage for this report:

```bash
claude-session-tokens --sum-from {token_baseline_line}
```

Parse the JSON output. Store `{report_tokens}` (the `total_tokens` value) and `{report_output_tokens}` (the `output_tokens` value) for use in the Data Sources section and Slack summary. The count is approximate (excludes the final message that writes the report).

Append the following line to the Data Sources section of the report:

```text
**Report token usage (approximate):** ~{report_tokens} total ({report_output_tokens} output). Excludes the final report-writing message.
```

#### Lint

Run markdownlint on the report if available:

```bash
npx markdownlint-cli {report_path} 2>&1 || true
```

Fix any lint errors. Then tell the user where the report was saved and offer a brief summary of the findings.

### Step 11: Copy Slack Summary

After saving the report, generate a condensed Slack summary in HTML format and copy it to the clipboard.

#### HTML Structure

Build an HTML snippet containing:

1. **Overall status** with the executive summary
2. **Action items** (if any), each as a list item
3. **Key metrics** (1-2 lines of the most important numbers)

Use the same HTML conventions as the standup skill:

```html
<p><b>{Service Name} {Window} Health: {Healthy | Degraded | Unhealthy}</b></p>
<p>{Executive summary sentence}</p>
<p><b>Action Items:</b></p>
<ul>
<li>[{Priority}] {Action title}: {Brief description}</li>
</ul>
<p><b>Key Metrics:</b></p>
<ul>
<li>Request rate: {value} | Error rate: {value} | P99 latency: {value}</li>
</ul>
<p><b>Tokens:</b> ~{report_tokens}</p>
<p>Full report: <code>{report_path}</code></p>
```

If there are no action items, replace the Action Items section with:

```html
<p>No action items. All metrics within normal ranges.</p>
```

#### Copy to Clipboard

```bash
swift ~/bin/copy-html-to-clipboard.swift <<'EOF'
{generated HTML}
EOF
```

Display: "Copied Slack summary to clipboard. Paste directly into Slack!"

## Assessment Criteria

Use these thresholds to determine the overall status:

| Status | Criteria |
| ------ | -------- |
| **Healthy** | Success rate >99%, P99 <500ms, no sustained error spikes, no restarts, no latency spikes |
| **Degraded** | Success rate 95-99%, P99 500ms-2s, brief error spikes, scaling pressure, or occasional minor latency spikes |
| **Unhealthy** | Success rate <95%, P99 >2s, sustained errors, restarts, pool exhaustion, frequent latency spikes, or any critical spikes |

## Writing Style

- Be factual and specific with numbers and timestamps
- Distinguish between transient blips (single data points) and sustained issues
- Don't alarm on known benign patterns (e.g., diurnal traffic drops)
- Note boundary artifacts (e.g., `increase()` at query range boundaries producing inflated first values)
- Cross-reference metrics to establish causation, not just correlation
- Lead with action items; the reader should know within 10 seconds whether the report needs their attention
- For each action item, document what investigation was already performed and what remains
- Keep next steps actionable and tied to specific observations
- Use UTC timestamps throughout
- Never use em dashes. Use commas, colons, parentheses, or periods instead
