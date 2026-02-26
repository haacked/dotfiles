---
name: ops-report
description: Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus metrics. Produces a formatted markdown report with key metrics, anomalies, and recommendations.
model: sonnet
color: green
allowed-tools: Bash, Read, Grep, Glob, Write, Edit, mcp__grafana__search_dashboards, mcp__grafana__get_dashboard_panel_queries, mcp__grafana__query_prometheus, mcp__grafana__query_prometheus_histogram, mcp__grafana__list_datasources, mcp__grafana__generate_deeplink, mcp__grafana__get_panel_image, mcp__claude-in-chrome__tabs_context_mcp, mcp__claude-in-chrome__tabs_create_mcp, mcp__claude-in-chrome__navigate, mcp__claude-in-chrome__computer, mcp__claude-in-chrome__resize_window, mcp__claude-in-chrome__javascript_tool
argument-hint: <service> [--hours N] [--region us|eu|dev]
---

# Ops Report

Generate a 24-hour operational health report for a PostHog service by querying Grafana dashboards and Prometheus/VictoriaMetrics metrics.

## Arguments (parsed from user input)

- **service** (required): The service to report on (e.g., `feature-flags`, `ingestion`, `capture`)
- **--hours N** (optional): Lookback window in hours (default: 24)
- **--region** (optional): Grafana region to query: `us`, `eu`, or `dev` (default: `us`)

Example invocations:

- `/ops-report feature-flags` - 24h report for feature flags (US)
- `/ops-report feature-flags --hours 12` - 12h report
- `/ops-report ingestion --region eu` - Ingestion report from EU

## Your Task

Follow these steps in order.

### Step 1: Parse Arguments and Validate

Extract from user input:

- `service` - required, kebab-case service name
- `hours` - lookback window, default 24
- `region` - default "us"

If service is missing, ask the user which service to report on.

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

### Step 8: Capture Dashboard Screenshots

Attempt to capture screenshots of the key dashboards. There are two methods, tried in order.

#### Method A: Grafana Image Renderer (fast, preferred)

```text
mcp__grafana__get_panel_image(
  dashboardUid="{uid}",
  timeRange={"from": "now-{hours}h", "to": "now"},
  width=1400, height=900, theme="light"
)
```

If this succeeds, save the returned image to the images directory. If it fails (common when using kubectl port-forward), fall back to Method B.

#### Method B: Browser Screenshot via Chrome Extension

This method navigates to each dashboard in Chrome (where the user is already Cognito-authenticated) and captures a screenshot. It requires the Claude in Chrome extension to be connected.

Step B1 - Check Chrome availability:

```text
mcp__claude-in-chrome__tabs_context_mcp(createIfEmpty=true)
```

If this returns an error ("No Chrome extension connected"), skip screenshots entirely and rely on dashboard links.

Step B2 - Create a tab and resize:

```text
mcp__claude-in-chrome__tabs_create_mcp()
mcp__claude-in-chrome__resize_window(width=1400, height=900, tabId={tabId})
```

Step B3 - For each key dashboard (overview, latency, cache), capture a screenshot:

Navigate to the public Grafana URL with `kiosk=1` parameter (hides the sidebar and header for cleaner screenshots):

```text
mcp__claude-in-chrome__navigate(
  tabId={tabId},
  url="https://{grafana_hostname}/d/{uid}?from=now-{hours}h&to=now&kiosk=1"
)
```

Wait for the dashboard to load (Grafana dashboards take several seconds to render all panels):

```text
mcp__claude-in-chrome__computer(action="wait", duration=8, tabId={tabId})
```

Take a screenshot:

```text
mcp__claude-in-chrome__computer(action="screenshot", tabId={tabId})
```

Then use JavaScript to capture the page as a base64 PNG and save it to disk:

```javascript
// In the browser tab, capture the visible viewport as base64
(async () => {
  const canvas = document.createElement('canvas');
  const ctx = canvas.getContext('2d');
  canvas.width = window.innerWidth;
  canvas.height = window.innerHeight;

  // Use the Grafana panel rendering if available, otherwise use html2canvas
  // Grafana exposes rendered panels as canvas elements
  const panels = document.querySelectorAll('.panel-content canvas, .panel-container canvas');
  if (panels.length > 0) {
    // Dashboard has canvas-rendered panels; the computer screenshot is better
    'use_computer_screenshot';
  } else {
    'use_computer_screenshot';
  }
})();
```

The `computer` screenshot captures the full viewport including all rendered Grafana panels (SVG, Canvas, and DOM elements). This is the most reliable capture method.

To save the screenshot to disk, use JavaScript to extract the page as a data URL via a Blob approach, or rely on the `computer` screenshot which is available inline in the conversation. If the screenshot needs to be embedded in the report as a file, note this in the report as "screenshots available in conversation" and include the dashboard links.

Step B4 - Save screenshots:

If screenshots were captured successfully, create the images directory and reference them in the report:

```bash
mkdir -p ~/dev/haacked/notes/PostHog/ops-reports/{YYYY-MM-DD}/images
```

Reference images in the report markdown as:

```markdown
![{Dashboard Title}](images/{dashboard-uid}.png)
```

**Note:** The `computer` screenshot action returns the image inline in the conversation. If you cannot programmatically save the screenshot to a file, skip the image embedding and instead note in the report that visual dashboard snapshots were reviewed during report generation, with links to the live dashboards.

### Step 9: Write the Report

Determine today's date from the system and write the report to:

```text
~/dev/haacked/notes/PostHog/ops-reports/{YYYY-MM-DD}/{service}.md
```

Create the directory if it doesn't exist. Only create an `images` subdirectory if screenshots were successfully saved to disk.

Use this structure for the report:

```markdown
# {Service Name} - {hours}-Hour Health Report

**Date:** {YYYY-MM-DD}
**Region:** {region description}
**Report window:** {start} to {end} UTC

## Overall Status: {Healthy | Degraded | Unhealthy}

{1-2 sentence executive summary}

## Dashboard Overview

{If screenshots were saved, embed them here:}

![Feature Flags - General](images/{dashboard-uid}.png)

{Otherwise, omit this section entirely.}

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

{e.g., HPA Scaling Pattern, Cache Performance, DB Connection Pool, etc.}

## Recommendations

1. {Actionable recommendation with context}

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
- Keep recommendations actionable and tied to specific observations
- Use UTC timestamps throughout

## What You Do NOT Do

- Guess at metric values without querying
- Report on dashboards that don't exist for the service
- Include screenshots that failed to render
- Create empty directories
- Use localhost URLs in the report
- Alarm on known benign patterns (e.g., diurnal traffic drops)
