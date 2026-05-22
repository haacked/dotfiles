# Handoff: {{ONE_LINE_GOAL}}

> Written for the next Claude session. Read this top to bottom, then start at **Next action**.
> This doc decays fast. If git state has moved since the snapshot, trust the code, not the doc.

## Snapshot

{{SNAPSHOT_BLOCK}}

## Goal

{{One sentence, outcome not task. Example: "Ship a working /handoff skill that bootstraps the next session." Not: "Finish implementing the skill."}}

## Status

{{Concrete bullets, one fact per bullet.}}

- ✅ {{works}}
- 🚧 {{in progress, where it stopped}}
- ❌ {{broken}}

## Next action

{{File:line specific, copy-pasteable if possible.}}

## Open decisions

{{Each: option A vs option B, leaning + reason, cost of changing later. Or "None."}}

- **{{decision}}**: {{A}} vs {{B}}. Leaning {{X}} because {{Y}}. Cost of changing later: {{low/medium/high}}.

## Ruled out

{{Approach + one-line reason.}}

- {{approach}}: {{why}}

## Verification

```bash
# {{what this verifies}}
{{command}}
```

## Key locations

{{Bookmark + one-line. No explanation, the reader can open the file.}}

- `{{path}}:{{line}}`, {{what's there}}

## Gotchas

{{Non-obvious traps not visible from reading code. Or "None."}}

- {{trap}}

## References

{{PR/issue/Slack. Omit section if empty.}}

- PR: {{url}}
- Issue: {{url}}
- Related: {{path or url}}
