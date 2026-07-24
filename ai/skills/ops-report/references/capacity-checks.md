# Service-Specific Capacity Checks

Capacity metrics that indicate approaching limits. All checks currently target the `feature-flags` service; other services have no entries yet. Run every query for each active region in parallel against that region's Prometheus datasource UID.

## Feature Flag Count Capacity

Query the number of feature flags per team to identify teams nearing the maximum allowed count:

- Total flag count per team/organization
- Teams approaching the configured maximum (e.g., >80% of the limit)
- Recent growth rate in flag creation

If a direct metric isn't available, check whether the dashboard panels show this data. Flag as an action item if any team is above 80% of the maximum.

## Scheduled Task Performance

Scheduled Celery task duration and verification fix counts from the cache dashboard. These tasks run periodically to maintain cache consistency.

**Task duration** (range query; compute min/max/avg per `task_name`; convert to human-readable, e.g. `~690s (11.5 min)`; replace `$__rate_interval` per the window mapping):

```promql
increase(posthog_celery_task_duration_seconds_sum{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\.(refresh_expiring_flags_cache_entries|cleanup_stale_flags_expiry_tracking_task)|posthog\\.tasks\\.team_metadata\\.(refresh_expiring_team_metadata_cache_entries|cleanup_stale_expiry_tracking_task)|posthog\\.tasks\\.team_access_cache_tasks\\.warm_all_team_access_caches_task"}[$__rate_interval])
/
increase(posthog_celery_task_duration_seconds_count{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\.(refresh_expiring_flags_cache_entries|cleanup_stale_flags_expiry_tracking_task)|posthog\\.tasks\\.team_metadata\\.(refresh_expiring_team_metadata_cache_entries|cleanup_stale_expiry_tracking_task)|posthog\\.tasks\\.team_access_cache_tasks\\.warm_all_team_access_caches_task"}[$__rate_interval])
```

**Verification fix counts** (cache inconsistencies detected and fixed; a non-zero count means self-healing is working, but sustained high counts or a sudden increase warrants investigation):

```promql
sum by(cache_type, issue_type) (increase(posthog_hypercache_verify_fixes_total[{window_hours}h]))
```

**Task failure counts** (any failures → action item):

```promql
sum by(task_name) (increase(posthog_celery_task_failure_total{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\..*|posthog\\.tasks\\.team_metadata\\..*"}[{window_hours}h]))
```

**Task execution count** (the "Runs" column in the scheduled tasks table):

```promql
sum by(task_name) (increase(posthog_celery_task_duration_seconds_count{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\.(refresh_expiring_flags_cache_entries|cleanup_stale_flags_expiry_tracking_task)|posthog\\.tasks\\.team_metadata\\.(refresh_expiring_team_metadata_cache_entries|cleanup_stale_expiry_tracking_task)|posthog\\.tasks\\.team_access_cache_tasks\\.warm_all_team_access_caches_task"}[{window_hours}h]))
```

**Task retry counts** (typically zero; include only when non-zero, as a footnote beneath the scheduled tasks table, not a column):

```promql
sum by(task_name) (increase(posthog_celery_task_retry_total{task_name=~"posthog\\.tasks\\.hypercache_verification\\..*|posthog\\.tasks\\.feature_flags\\..*|posthog\\.tasks\\.team_metadata\\..*"}[{window_hours}h]))
```

**Queue health** (queue-level, not per-task; render as a separate sub-section after the scheduled tasks table):

```promql
avg_over_time(posthog_celery_queue_depth{queue=~"feature_flags|feature_flags_long_running"}[{window_hours}h])
max_over_time(posthog_celery_queue_depth{queue=~"feature_flags|feature_flags_long_running"}[{window_hours}h])
deriv(posthog_celery_queue_depth{queue=~"feature_flags|feature_flags_long_running"}[{window_hours}h])
```

Classify the trend from `deriv`: `> 0.1` = "Growing", `< -0.1` = "Draining", otherwise "Stable".

**Batch refresh coverage** (instant query; teams processed by the most recent batch refresh, broken down by `namespace` and `status`; any failures → action item):

```promql
posthog_hypercache_teams_processed_last_run{namespace=~"feature_flags|team_metadata"}
```

**Fallback:** if any of the standard Celery task metrics return no data, omit that sub-section from the report rather than reporting zeros.

## Sync Task Health (`sync_feature_flag_last_called`)

This task uses custom Prometheus metrics rather than the standard Celery task instrumentation, so it requires separate queries.

**Success rate** (0–1 value; multiply by 100 and report as a percentage):

```promql
avg_over_time(posthog_celery_sync_feature_flag_last_called_success[{window_hours}h])
```

**Duration** (range query; compute min/max/avg; report the average in the Avg Duration column and use min/max to inform the Assessment, e.g. high variance or an increasing trend; format as `~Xs` under 60s, `~Y.Z min` over):

```promql
posthog_celery_sync_feature_flag_last_called_duration_seconds
```

**Execution count** (counts duration-gauge changes as a proxy for runs; approximate — two consecutive runs with identical durations may miss one execution):

```promql
changes(posthog_celery_sync_feature_flag_last_called_duration_seconds[{window_hours}h])
```

**Interpretation thresholds:**

- Success rate < 100%: action item. < 90% = Warning priority, < 50% = Critical priority
- Zero executions in the window: action item (task not running)
- Duration increasing trend: note in the report for monitoring

## HPA Scaling Efficiency

Three metrics to assess whether the HPA is tuned correctly.

**% time at max replicas:**

```promql
count_over_time((kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="posthog-feature-flags"} >= kube_horizontalpodautoscaler_spec_max_replicas{horizontalpodautoscaler="posthog-feature-flags"})[{window_hours}h:5m])
/ count_over_time(kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="posthog-feature-flags"}[{window_hours}h:5m])
```

**CPU headroom ratio** (range query; how close the hottest pod is to the HPA target):

```promql
max(sum by (pod)(rate(container_cpu_usage_seconds_total{namespace="posthog", container="posthog-feature-flags"}[5m])) / on(pod) sum by (pod)(kube_pod_container_resource_requests{resource="cpu", namespace="posthog", container="posthog-feature-flags"})) / 0.70
```

**Scaling events** (HPA replica changes in the window):

```promql
changes(kube_horizontalpodautoscaler_status_desired_replicas{horizontalpodautoscaler="posthog-feature-flags"}[{window_hours}h])
```

**Interpretation thresholds:**

- % at max > 20% → action item (raise maxPods or lower CPU target)
- Headroom ratio peak > 0.9 → HPA being pushed close to scaling
- Headroom ratio peak < 0.5 → CPU target may be too conservative

**Fallback:** if any of these metrics return no data, omit the HPA Scaling Efficiency section from the report.

## Billing Aggregator

The billing aggregator is the sole authoritative writer for flag billing counts. A silent failure here under-bills usage with no immediate symptom in latency or error rate, so it gets its own health check.

**Stale-flush watchdog** (instant, max across pods; default flush interval is 10 seconds — healthy pods sit well under 30s, sustained over 60s is a real problem):

```promql
max(flags_billing_seconds_since_successful_flush)
```

**Unflushed requests by cause** (the revenue-loss signal; any sustained non-zero total is an action item):

```promql
sum by(cause) (increase(flags_billing_unflushed_requests_total[{window_hours}h]))
```

Causes: `cap_drop` (memory-pressure shed at record-time), `redis_error` (chunk failed mid-flush; even though the requeue may succeed, the request count is booked here so the total reflects everything blocked), `flush_dropped_on_error` (best-effort shutdown gave up on a chunk), `shutdown_drop` (process exited before draining in-memory state).

**Flush errors by type** (a non-zero count that does not pair with `unflushed_requests_total` growth means flushes are retrying successfully; pair with the query above before deciding severity):

```promql
sum by(error_type) (increase(flags_billing_flush_errors_total[{window_hours}h]))
```

**Pending queue depth** (in-memory records waiting to flush; should drop to ~0 each tick — sustained growth is a leading indicator that `cap_drop` is imminent):

```promql
max_over_time(sum(flags_billing_pending_records)[{window_hours}h:])
```

**Throughput** (input vs flushed-out rate; over a stable window the two rates should match — a widening gap means the buffer is filling faster than it drains):

```promql
sum(rate(flags_billing_records_total[$__rate_interval]))
sum(rate(flags_billing_entries_flushed_total[$__rate_interval]))
```

**Flush latency** (p99 trending toward the 10s tick interval means flushes risk overlapping the next tick; rising p99 + rising pending depth points at Redis as the bottleneck):

```promql
histogram_quantile(0.99, sum by(le) (rate(flags_billing_flush_duration_ms_bucket[$__rate_interval])))
```

**Interpretation thresholds:**

- Stale-flush > 60s sustained → action item (Warning). > 120s → Critical
- Any non-zero `unflushed_requests_total` over the window → action item. `cap_drop` or `shutdown_drop` totals > 0 are Critical (records definitely lost). `redis_error` and `flush_dropped_on_error` are Warning by default; promote to Critical if paired with stale-flush or sustained pending growth
- Pending records depth growing trend over the window → Warning (lead time before cap_drop fires)
- Records-in / entries-flushed ratio drifting from 1.0 across the window → Warning
- Flush p99 > 5000ms sustained → Warning (half the tick interval). > 9000ms → Critical

**Fallback:** if `flags_billing_records_total` returns no data (the service may not have rolled out the aggregator yet), omit the Billing Aggregator section from the report.
