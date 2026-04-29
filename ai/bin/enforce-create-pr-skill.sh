#!/usr/bin/env bash
# Claude Code PreToolUse hook for Bash.
# Denies bare `gh pr create` invocations and points Claude at the /create-pr
# skill, which fills templates, picks the right base for stacked PRs, and
# applies the user's voice/style rules.
#
# Escape hatch: the create-pr skill prefixes its `gh pr create` with a no-op
# marker (`: __create-pr-skill__ ;`). When the marker is present, this hook
# allows the command through.

if ! command -v jq >/dev/null 2>&1; then
  exit 0
fi

INPUT=$(cat)
CMD=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // empty')
[ -z "$CMD" ] && exit 0

# Match `gh pr create` at a command boundary (start, after ;, &, |, &&, ||,
# backtick, or whitespace). Excludes things like `gh pr create-something`.
if ! printf '%s' "$CMD" | grep -Eq '(^|[;&|`( ]|&&|\|\|)gh[[:space:]]+pr[[:space:]]+create([[:space:]]|$)'; then
  exit 0
fi

# Skill marker present — allow.
if printf '%s' "$CMD" | grep -Fq '__create-pr-skill__'; then
  exit 0
fi

jq -n '
  {
    "hookSpecificOutput": {
      "hookEventName": "PreToolUse",
      "permissionDecision": "deny",
      "permissionDecisionReason": "Use the /create-pr skill to create or update PRs. It detects PR templates, handles stacked-PR bases, applies the configured voice and style rules, and embeds saved test plans. Invoke the skill instead of running `gh pr create` directly."
    }
  }
'
