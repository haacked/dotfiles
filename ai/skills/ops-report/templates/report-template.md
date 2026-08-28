# {Service Name} - {Window Label} Health Report

**Date:** {YYYY-MM-DD}
**Regions:** {US (prod-us) | EU (prod-eu) | US + EU (prod-us, prod-eu)}
**Report window:** {start} to {end} UTC

## Overall Status: {Healthy | Degraded | Unhealthy}

{1-2 sentence executive summary}

## Action Items

{This section appears first so the reader immediately knows what needs attention. Each item describes the anomaly, what investigation was already performed during report generation, and concrete next steps. If no action items exist, write "No action items. All metrics are within normal ranges."}

### {Priority}: {Action title}

- **What:** {Brief description of the anomaly or concern}
- **Evidence:** {Specific metric values, timestamps, and correlated signals}
- **Recurrence:** {The `{recurrence_line}` from Step 6b.}
- **Investigation so far:** {What was checked during report generation, e.g., "Correlated with deploy times - no deploys in this window" or "Error logs show timeout to downstream service X"}
- **Next steps:** {Concrete actions, e.g., "Check service X health", "Review recent deploy for regression", "Monitor for recurrence over next 24h"}

## Key Metrics Summary

{When reporting on both regions, use US and EU columns so the reader can compare at a glance. For single-region reports, collapse to Metric | Current | Range | Assessment.}

| Metric | US Current | US Range | EU Current | EU Range | Assessment |
| --- | --- | --- | --- | --- | --- |
| {metric} | {value} | {min–max} | {value} | {min–max} | {assessment} |

{Include an "Error spikes (5xx > 50/5min)" row after the error rate row, showing the spike count and severity breakdown. Include a "Latency spikes (P99 > {threshold}ms)" row after the P50 latency row. For dual-region, show the spike count and severity breakdown for each region separately in their respective columns. The latency {threshold} value is max(2 × median P99, 200).}

## Anomalies and Notable Events

### 1. {Event title}

{Description with timestamps and correlated metrics}

**Recurrence:** {The same line as the matching action item, or the Step 6b line directly if this anomaly has no action item.}

## What's Working Well

- {Bullet points of positive signals}

## Scheduled Tasks

{When reporting on both regions, render a separate sub-section for each region; for single-region reports, omit the sub-section headers.}

### US (prod-us)

| Task | Runs | Min | Max | Avg | Fixes ({window}) |
| --- | --- | --- | --- | --- | --- |
| `{task_short_name}` | {N} | {~X.X min} | {~X.X min} | {~X.X min} | {N} |

### EU (prod-eu)

{Same table shape as US.}

{Use the short task name (e.g., `verify_and_fix_flags_cache_task`) rather than the full dotted path. For durations, use `~Xs` for values under 60s and `~Y.Z min` for values over 60s. For the Fixes column, show the total count and bold it if non-zero, appending the issue types in parentheses (e.g., **3** (cache_mismatch)). If a task had failures, note them in a row below or as a footnote. Omit tasks that had zero runs in the window. If any tasks had retries during the window, annotate the task name with an asterisk and add a footnote below the table (e.g., `*3 retries during the window`). Omit the footnote entirely when all retry counts are zero.}

### Sync Task Health (`sync_feature_flag_last_called`)

This task uses custom metrics (not standard Celery task instrumentation).

| Region | Runs | Avg Duration | Success Rate | Assessment |
| --- | --- | --- | --- | --- |
| US | {N} | {~Xs} | {XX%} | {Healthy / Degraded / Not Running} |
| EU | {N} | {~Xs} | {XX%} | {Healthy / Degraded / Not Running} |

{Report 0 runs as "Not Running" with a warning. Success rate < 100% should be flagged as an action item. For single-region reports, omit the Region column. Omit this sub-section entirely if the custom metrics return no data for both regions.}

### Queue Health

| Region | Queue | Avg Depth | Max Depth | Trend |
| --- | --- | --- | --- | --- |
| {US/EU} | `{queue_name}` | {N} | {N} | {Stable/Growing/Draining} |

{Show average and maximum queue depth over the window, plus the trend derived from `deriv()`: "Growing" (deriv > 0.1), "Draining" (deriv < -0.1), or "Stable" (near zero). A growing queue paired with increasing task durations warrants investigation. Omit this section if queue depth metrics return no data for both regions.}

### Batch Refresh Coverage

{One-line summary per region of `posthog_hypercache_teams_processed_last_run` results, e.g., "**US:** Batch refresh processed N teams (feature_flags) and M teams (team_metadata) with no failures. **EU:** ..." If any failures are present, bold the failure count and flag as an action item. Omit this section if the metric returns no data for either region.}

## Billing Aggregator

The aggregator is the sole authoritative writer for flag billing counts; a silent failure under-bills usage without showing up in latency or error metrics.

| Region | Signal | Value | Assessment |
| --- | --- | --- | --- |
| {US/EU} | Seconds since last successful flush (max pod) | {Xs} | {Healthy / Drifting / Stale} |
| {US/EU} | Unflushed requests ({window}) | {N total (cause breakdown)} | {None / Warning / Critical} |
| {US/EU} | Flush errors ({window}) | {N (error_type breakdown)} | {None / Transient / Sustained} |
| {US/EU} | Pending records (max / trend) | {N max, Stable/Growing} | {Healthy / Backing up} |
| {US/EU} | Records-in vs entries-flushed | {X.XX ratio} | {Matched / Diverging} |
| {US/EU} | Flush p99 | {Xms} | {Healthy / Tight / At-tick} |

{Classify Seconds since last flush: Healthy (<30s), Drifting (30–60s), Stale (>60s). Unflushed requests: None (0), Warning (any non-zero with cause = redis_error / flush_dropped_on_error), Critical (any non-zero with cause = cap_drop / shutdown_drop — these are confirmed lost). Pending records: Healthy (drains to ~0 each tick, no trend), Backing up (sustained growth across the window). Records vs flushed ratio: Matched (0.95–1.05), Diverging (outside that band sustained). Flush p99: Healthy (<5s), Tight (5–9s), At-tick (>9s, risks overlapping next tick).}

{If any signal lands in a non-healthy band, add a corresponding action item to the top of the report describing the signal, the cause/error_type breakdown, and the next step (typically: check Redis health, then inspect aggregator pod logs at the spike time).}

{Omit this entire section if `flags_billing_records_total` returned no data for both regions.}

## HPA Scaling Efficiency

| Region | Metric | Value | Assessment |
| --- | --- | --- | --- |
| {US/EU} | Time at max replicas | {X%} | {OK / Elevated / Critical} |
| {US/EU} | CPU headroom (max pod / target) | {X.XX avg, X.XX peak} | {Comfortable / Tight / Over-target} |
| {US/EU} | Scaling events | {N} | {Stable / Moderate / Volatile} |

## Warning and Error Logs

Summary of warning and error log messages observed across the full reporting window.

### Errors

{When reporting on both regions, use sub-sections per region. For each region, list the top recurring error patterns. If no errors were logged, write: "No error-level log messages observed in this window."}

| Count | Message Pattern | First Seen | Last Seen |
| --- | --- | --- | --- |
| {N} | `{short description of the error pattern}` | {HH:MM} UTC | {HH:MM} UTC |

### Warnings

{Same table shape as Errors. If no warnings were logged, write: "No warning-level log messages observed in this window."}

{Cross-reference any log patterns against the anomalies identified during analysis. If a log pattern correlates with a metric spike, note it here and link to the relevant anomaly section. Promote recurring or high-volume error patterns to the Action Items section if they warrant investigation.}

### Worker Task Logs

{Summary of service-related error and warning messages from `posthog-worker-django` across the full reporting window, same table shape as Errors, with sub-sections per region for dual-region reports. If no worker task errors or warnings were logged, write: "No service-related worker task log messages observed in this window." Only omit this sub-section if worker log queries could not be run or no worker log datasource is available for both regions.}

{Cross-reference worker error patterns against the `sync_feature_flag_last_called` success rate from the Scheduled Tasks section. If a worker error pattern correlates with a low success rate, note it and link to the relevant section. Promote high-volume worker errors to Action Items if they indicate a systemic issue.}

## {Service-specific sections as appropriate}

{e.g., Cache Performance, DB Connection Pool, Capacity/Limits, etc.}

## Dashboard Links

These links require VPN access and Cognito authentication:

### US dashboards (prod-us)

- [{Dashboard Name}](grafana.prod-us.posthog.dev/...)

### EU dashboards (prod-eu)

- [{Dashboard Name}](grafana.prod-eu.posthog.dev/...)

## Data Sources

{Brief description of how the data was collected}
