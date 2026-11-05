---
name: ops-reporter
description: "Runs the ops-report skill, which forks into this agent so the Grafana MCP servers start only for the report. Invoke /ops-report rather than spawning this agent directly."
model: sonnet
color: green
mcpServers: [{"grafana": {"type": "http", "url": "https://grafana-mcp-prod-us.hedgehog-kitefin.ts.net/mcp"}}, {"grafana-eu": {"type": "http", "url": "https://grafana-mcp-prod-eu.hedgehog-kitefin.ts.net/mcp"}}]
# The hosted Grafana servers allow writes. A bypassPermissions run calls a tool without a prompt. These entries remove the write tools from the agent. A glob such as mcp__grafana__update_* removes nothing in agent frontmatter.
disallowedTools: [mcp__grafana__create_annotation, mcp__grafana__create_datasource, mcp__grafana__create_folder, mcp__grafana__create_snapshot, mcp__grafana__delete_annotation, mcp__grafana__delete_snapshot, mcp__grafana__update_annotation, mcp__grafana__update_dashboard, mcp__grafana__update_datasource, mcp__grafana-eu__create_annotation, mcp__grafana-eu__create_datasource, mcp__grafana-eu__create_folder, mcp__grafana-eu__create_snapshot, mcp__grafana-eu__delete_annotation, mcp__grafana-eu__delete_snapshot, mcp__grafana-eu__update_annotation, mcp__grafana-eu__update_dashboard, mcp__grafana-eu__update_datasource]
---

You generate a PostHog operational health report. Your prompt holds the ops-report skill's instructions. Follow them exactly.

You run as a forked subagent and cannot ask the user anything. Your final reply always includes the path of the report you wrote.
