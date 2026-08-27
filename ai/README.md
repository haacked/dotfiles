# AI Settings

This directory contains shared configuration for Claude Code and Codex. Skills, agent instructions, global guidance, and MCP server definitions have one canonical source; the installers handle each platform's file layout and metadata.

## Installation

Run `install.sh` to configure both platforms:

```sh
ai/install.sh
```

Install one platform with `--claude-only` or `--codex-only`. Component flags such as `--skills-only`, `--agents-only`, `--mcp-only`, `--instructions-only`, and `--no-mcp` are forwarded to the selected installers. The platform installers can also be run directly as `install-claude.sh` and `install-codex.sh`.

Re-run `ai/install.sh` after pulling. Skills reach repo binaries and each other through `~/.dotfiles/ai/skills/…`, and the matching tool-permission entry only lands when the installer runs; until then those calls prompt for approval.

The installers preserve regular files and unmanaged symlinks in the destination directories, and report any destination they could not claim. Uninstall removes only links and generated agent files owned by this repository; MCP servers and hand-written configuration remain in place.

## Shared sources

- `AGENTS.md` contains global instructions and is linked as `~/.claude/CLAUDE.md` and `~/.codex/AGENTS.md`.
- `skills/` is linked into `~/.claude/skills/` and `~/.agents/skills/`, subject to each platform's exclusions. A skill refers to its own scripts relative to its directory so it resolves under either agent; an absolute `~/.dotfiles/…` path means it reaches outside itself, to a repo binary or another skill. Codex exclusions live in `codex/excluded-skills.txt`; they cover configuration workflows, orchestrators that still depend on Claude-only slash commands or external Claude skills, and skills whose `allowed-tools` fence matters because they read untrusted input, since Codex has no per-skill tool scoping. Claude exclusions live in `claude/excluded-skills.txt`; they prevent personal skills from overriding bundled Claude workflows with the same name.
- `agents/` contains the canonical Markdown agent definitions. Claude consumes them directly and `bin/render-codex-agents.py` converts them to Codex TOML.
- `mcp-servers.sh` defines the MCP inventory once while each installer uses its platform's registration command.

## Model tiers

Skills retain Claude's native `model` field and declare a provider-neutral `metadata.execution-tier`. Codex global instructions route pinned skills through the corresponding custom runner:

| Tier | Claude | Codex | Reasoning effort |
| --- | --- | --- | --- |
| `fast` | Haiku | `gpt-5.6-luna` | `low` |
| `balanced` | Sonnet | `gpt-5.6-terra` | `medium` |
| `deep` | Opus | `gpt-5.6-sol` | `high` |
| `inherit` | Parent model | Parent model | Parent effort |

The machine-readable mapping lives in `codex/model-tiers.conf`. The agent renderer uses it for both converted Markdown subagents and generated skill-runner agents.

## Tests

Run the installer and portability tests with:

```sh
ai/tests/test-ai-installers.sh
ai/tests/test-canonical-skills.sh
ai/tests/test-plain-writing-contract.sh
python3 ai/skills/plain-writing/scripts/tests/test_plain_writing_lint.py
ai/tests/test-skill-spec.sh
```

`test-skill-spec.sh` validates every skill against the agentskills.io spec: directory name equals the frontmatter `name`, `description` is 1–1024 characters, and frontmatter only uses spec keys plus this repo's own extensions (`argument-hint`, `model`, `color`). Skills listed in `codex/excluded-skills.txt` also carry `compatibility: Designed for Claude Code (or similar products)` so spec-aware clients know they are Claude-only.
