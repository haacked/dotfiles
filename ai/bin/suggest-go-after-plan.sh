#!/usr/bin/env bash
# Claude Code PostToolUse hook for ExitPlanMode.
# After a plan is approved, nudges Claude to implement it via the /go skill
# instead of ad hoc, so it gets the full plan -> PR -> review loop.

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  exit 0
fi

if ! git remote -v 2>/dev/null | grep -q 'github\.com'; then
  exit 0
fi

INPUT=$(cat)

# ExitPlanMode's tool result always contains a line like:
#   Your plan has been saved to: /Users/you/.claude/plans/<slug>.md
# Grep the raw stdin for that path rather than assuming tool_response's JSON
# field nesting, which isn't documented. Anchor on "saved to:" and stop only
# at the JSON string's closing quote (not at spaces), so paths containing
# spaces (e.g. a home directory like "/Users/John Doe/...") still match.
PLAN_FILE=$(printf '%s' "$INPUT" | grep -oE 'saved to:[^"]*\.claude/plans/[^"]*\.md' | sed -E 's/^saved to: *//' | head -1)

if [ -z "$PLAN_FILE" ]; then
  # Fallback: most recently modified plan file, but only if it was touched in
  # the last 2 minutes — otherwise a format change upstream could silently
  # point Claude at a stale, unrelated plan instead of failing closed.
  PLAN_FILE=$(find "$HOME/.claude/plans" -maxdepth 1 -name '*.md' -newermt '-2 minutes' -exec ls -t {} + 2>/dev/null | head -1)
fi

[ -z "$PLAN_FILE" ] && exit 0

jq -n --arg path "$PLAN_FILE" '
  {
    "hookSpecificOutput": {
      "hookEventName": "PostToolUse",
      "additionalContext": ("The plan at " + $path + " was just approved. Implement it now via the go skill instead of implementing directly: Skill(\"go\", args: \"--plan-file " + $path + "\"). Do not re-plan or ask what to build — jump straight to implementation using this plan.")
    }
  }
'
