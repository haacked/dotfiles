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
- `skills/` is linked into both `~/.claude/skills/` and `~/.agents/skills/`. A skill refers to its own scripts relative to its directory so it resolves under either agent; an absolute `~/.dotfiles/…` path means it reaches outside itself, to a repo binary or another skill. Codex exclusions live in `codex/excluded-skills.txt`; they cover configuration workflows, orchestrators that still depend on Claude-only slash commands or external Claude skills, and skills whose `allowed-tools` fence matters because they read untrusted input, since Codex has no per-skill tool scoping.
- `codex/skills/` is linked into `~/.agents/skills/` only. It holds skills that exist because Claude bundles its own workflow under that name, so shipping ours to Claude would override the bundled one. Both roots land in the same destination directory, so a name may appear in only one of them.
- `agents/` contains the canonical Markdown agent definitions. Claude consumes them directly and `bin/render-codex-agents.py` converts them to Codex TOML.
- `mcp-servers.sh` defines the MCP inventory once while each installer uses its platform's registration command.

## Portable skills

A cloud agent run uploads one skill folder into a sandbox that has no clone of this repo, so a skill listed in `ai/helpers/portable-skills.sh` has to work with nothing but its own directory. Such a skill carries a copy of every helper it calls under its `scripts/`, and its `SKILL.md` names no path outside that folder. The same `SKILL.md` also names no other skill with a leading slash, because PostHog Desktop reads `/other-skill` as a dependency and refuses the upload when that skill is a symlink the user did not select. `wait-for-pr-reviews` and `address-pr-reviews` are portable today.

Edit a helper where the table says it comes from, then run `ai/bin/sync-portable-skills.sh` and commit the refreshed copies. Editing the copy instead loses the edit to the next sync, so `--check` names the source file to open. A copy and a hand-maintained script sit side by side in the same `scripts/` folder and look alike, so `PORTABLE_SKILL_OWN_FILES` in the same table file lists the scripts a skill owns. Anything in the folder that neither list names is what a renamed or deleted row leaves behind: `--check` reports it, and a plain run deletes it.

CI enforces all three rules: the same script with `--check` rejects a missing, stale, wrongly permissioned, or undeclared copy, `ai/tests/test-portable-skills.sh` rejects a `SKILL.md` that reaches outside its folder, and each skill's `scripts/tests/test-portable-skill.sh` runs the copied folder with an empty environment so anything left reaching outside it fails there. Those last two guards have tests of their own, `ai/tests/test-portable-skills-lint.sh` and `ai/tests/test-portable-sync.sh`, which drive them over fixture trees so their reject branches run.

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
ai/tests/test-skill-spec.sh
ai/tests/test-canonical-skills.sh
ai/bin/sync-portable-skills.sh --check
ai/tests/test-portable-sync.sh
ai/tests/test-portable-skills.sh
ai/tests/test-portable-skills-lint.sh
ai/skills/wait-for-pr-reviews/scripts/tests/test-pending-reviews.sh
ai/skills/wait-for-pr-reviews/scripts/tests/test-portable-skill.sh
ai/skills/address-pr-reviews/scripts/tests/test-portable-skill.sh
ai/tests/test-plain-writing-contract.sh
python3 ai/skills/plain-writing/scripts/tests/test_plain_writing_lint.py
ai/tests/test-ai-installers.sh
ai/tests/test-command-log.sh
ai/tests/test-log-step-done.sh
ai/skills/ran/scripts/tests/test-ran-report.sh
ai/helpers/tests/test-repo-context.sh
bin/lib/test-git-pr.sh
bin/lib/test-dismissed-state.sh
```

That is the CI list from `.github/workflows/test.yml`, in order, plus `test_plain_writing_lint.py`, which CI does not run.

`test-skill-spec.sh` validates every skill against the agentskills.io spec: directory name equals the frontmatter `name`, `description` is 1–1024 characters, and frontmatter only uses spec keys plus this repo's own extensions (`argument-hint`, `model`, `color`). Skills listed in `codex/excluded-skills.txt` also carry `compatibility: Designed for Claude Code (or similar products)` so spec-aware clients know they are Claude-only.
