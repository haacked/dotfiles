---
name: simplify
description: Simplify recently changed code for clarity, consistency, and maintainability while preserving behavior. Use after implementation or when asked to simplify or refactor code without changing what it does.
model: opus
metadata:
  execution-tier: deep
---

# Simplify

Improve recently changed code without changing its observable behavior.

## Scope

Use the files or code the user names. Otherwise, inspect the working tree and branch diff and focus on code changed for the current task. Preserve unrelated user changes and avoid broad cleanup outside that scope.

If there is no changed code and the user did not name a target, ask what code to simplify.

## Review and edit

Read the applicable repository instructions and nearby code before editing. Apply changes that materially improve clarity, consistency, or maintainability, including:

- Reduce unnecessary nesting, indirection, duplication, and special cases.
- Remove abstractions or helpers that do not earn their complexity.
- Make data flow, names, and control flow easier to follow.
- Remove comments that only restate the code, while preserving comments that explain non-obvious constraints.
- Align changed code with established project patterns.

Prefer explicit, readable code over compressed expressions. Do not optimize for fewer lines, introduce speculative abstractions, expand the task, or change public behavior.

Apply safe improvements directly. Leave ambiguous or behavior-changing opportunities untouched and report them to the user.

## Verify

Run the most relevant formatter, linter, and focused tests for the changed code. Finish with a concise summary of material simplifications, verification performed, and anything left unchanged because it requires user judgment.
