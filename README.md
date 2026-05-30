# haacked dotfiles

Your dotfiles are how you personalize your system. These are mine.

They're so personal I copied much of them from <https://github.com/holman/dotfiles> including the approach to install them.

## Install

On a brand-new Mac, run the one-liner. It installs the Xcode Command Line Tools (for git), clones this repo to `~/.dotfiles`, and runs `script/bootstrap`:

```sh
curl -fsSL https://raw.githubusercontent.com/haacked/dotfiles/main/install.sh | bash
```

Prefer to do it by hand (requires git, i.e. Xcode Command Line Tools, already installed):

```sh
git clone https://github.com/haacked/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
script/bootstrap
```

Either way symlinks the appropriate files in `.dotfiles` into your home directory. Everything is configured and tweaked within `~/.dotfiles`. The installer points the `origin` remote at SSH, so add an SSH key to GitHub before you push.

The main file you'll want to change right off the bat is `zsh/zshrc.symlink`, which sets up a few paths that'll be different on your particular machine.

`dot` is a simple script that installs some dependencies, sets sane macOS defaults, and so on. Tweak this script, and occasionally run `dot` from time to time to keep your environment fresh and up to date. You can find this script in `bin/`.

### ZSH

`~/.zshrc` is managed by this repo via `zsh/zshrc.symlink`. Running `script/bootstrap` creates the symlink automatically.

### Claude Code

The `ai/` directory contains Claude Code configuration: a global `CLAUDE.md`, subagents, skills, and helper hooks. Run `ai/install.sh` to symlink them into `~/.claude` and install the configured MCP servers. See [`ai/README.md`](ai/README.md) for details.

## Inventory

This repo ships a fair amount of tooling: Claude Code skills and subagents, shell scripts, git helpers, and macOS utilities. The tables below are an organized inventory so you (or a colleague) can find what's useful.

### Claude skills

Skills live in [`ai/skills/`](ai/skills) and are installed into `~/.claude/skills/` by `ai/install.sh`. Each skill is a self-contained directory with a `SKILL.md` and any supporting scripts.

| Skill | What it does |
| ------- | ------------ |
| [`analyze-permissions`](ai/skills/analyze-permissions) | Analyze accumulated Claude Code permissions and suggest smart wildcard patterns. |
| [`ci-monitor`](ai/skills/ci-monitor) | Monitor CI checks after pushing, distinguish flaky from real failures, auto-fix. |
| [`commit`](ai/skills/commit) | Commit staged/unstaged changes with a well-crafted commit message. |
| [`copilot-review`](ai/skills/copilot-review) | Evaluate Copilot PR review comments, fix legitimate issues, reply to dismissed ones. |
| [`create-pr`](ai/skills/create-pr) | Create or update a GitHub PR with automatic template detection and filling. |
| [`go`](ai/skills/go) | Plan, implement, and iteratively review a task end to end using Claude plus Copilot reviewers. |
| [`metabase-prod-query`](ai/skills/metabase-prod-query) | Guarded workflow for querying PostHog production Metabase via `hogli metabase:*`. |
| [`note`](ai/skills/note) | Capture complex technical discoveries into structured, reusable notes. |
| [`ops-report`](ai/skills/ops-report) | Generate a 24-hour operational health report for a PostHog service via Grafana and Prometheus. |
| [`postmortem`](ai/skills/postmortem) | Write incident postmortems using the DERP model (Detection, Escalation, Recovery, Prevention). |
| [`resolve-conflicts`](ai/skills/resolve-conflicts) | Resolve git conflicts with mergiraf structural merging, lock file handling, stacked PR dedup. |
| [`review-fix-cycle`](ai/skills/review-fix-cycle) | One review, fix, simplify, commit iteration. |
| [`sprint-planning`](ai/skills/sprint-planning) | Bi-weekly sprint planning updates for the Feature Flags Platform team. |
| [`standup`](ai/skills/standup) | Generate standup notes from your recent GitHub PR activity. |
| [`support`](ai/skills/support) | Support hero workflow: start ticket investigations, find prior notes, generate weekly highlights. |
| [`test-plan`](ai/skills/test-plan) | Generate a manual test plan checklist focused on scenarios uncovered by existing tests. |
| [`triage-issues`](ai/skills/triage-issues) | Identify unlabeled GitHub issues that may belong to a specific team. |

The `squash` command lives at [`ai/commands/squash.md`](ai/commands/squash.md): squash developer commits on the current branch into one while preserving CI snapshot commits.

### Claude subagents

Subagents live in [`ai/agents/`](ai/agents) and are installed into `~/.claude/agents/`.

| Agent | When to use it |
| ------- | -------------- |
| [`bug-root-cause-analyzer`](ai/agents/bug-root-cause-analyzer.md) | Failing tests, intermittent bugs, or environment-specific defects that need a systematic investigation. |
| [`code-reviewer`](ai/agents/code-reviewer.md) | Pre-commit correctness, security, and guideline review (use `/simplify` for readability). |
| [`implementation-planner`](ai/agents/implementation-planner.md) | Break down complex features into staged technical plans before writing code. |
| [`investigator`](ai/agents/investigator.md) | Investigate a single operational hypothesis using Grafana, Prometheus, Loki, and PostHog data. Spawn in parallel for multi-hypothesis incident reviews. |
| [`note-taker`](ai/agents/note-taker.md) | Preserve non-obvious technical discoveries after a long exploration session. |
| [`prompt-optimizer`](ai/agents/prompt-optimizer.md) | Refine system prompts that aren't producing the output you want. |
| [`support`](ai/agents/support.md) | Customer support investigations that need debugging plus documentation. |
| [`task-orchestrator`](ai/agents/task-orchestrator.md) | Decide which agents to use, and in what order, for a complex task. |
| [`triage-feature-flags`](ai/agents/triage-feature-flags.md) | Identify GitHub issues that belong to the Feature Flags team domain. Used by the `triage-issues` skill. |
| [`unit-test-writer`](ai/agents/unit-test-writer.md) | Write comprehensive unit tests for new or untested code, or to set up TDD scaffolding. |

### Scripts

Scripts live in [`bin/`](bin) and are added to `PATH` via `zsh/zshrc.symlink`.

#### Git and PR workflow

| Script | Purpose |
| ------ | ------- |
| [`tree-me`](bin/tree-me) | Minimal git worktree wrapper that organizes worktrees under `~/dev/worktrees/<repo>/<branch>` and supports auto-cd and tab completion. See [`bin/README-tree-me.md`](bin/README-tree-me.md). |
| [`git-branches`](bin/git-branches) | `git branch` listing enhanced with associated open PR numbers and URLs. |
| [`git-bclean-empty`](bin/git-bclean-empty) | Delete local branches that are ancestors of the default branch with no upstream and no worktree. |
| [`git-bclean-local`](bin/git-bclean-local) | Delete local branches whose remote tracking branch is gone (post-merge cleanup), removing their worktrees first. |
| [`git-delete-others`](bin/git-delete-others) | Delete local branches you didn't create and haven't modified; keeps branches matching your configured prefix. |
| [`git-https-to-ssh`](bin/git-https-to-ssh) | Convert HTTPS remotes to SSH across every repo under a directory (default `~/dev`). |
| [`convert-to-blobless.sh`](bin/convert-to-blobless.sh) | Re-clone an existing repo as a `--filter=blob:none` blobless partial clone, preserving local branches. |
| [`detect-pr.sh`](bin/detect-pr.sh) | Detect a PR from a URL, number, or current branch and emit TSV or JSON. |
| [`gh-resolve-threads`](bin/gh-resolve-threads) | List and resolve GitHub PR review threads (outdated, all, or by comment ID). |
| [`pr-review.sh`](bin/pr-review.sh) | Manage your pending (draft) GitHub PR reviews: `pending` and `submit` subcommands. Aliased as `pr-review` / `submit-review`. |
| [`team-prs.sh`](bin/team-prs.sh) | Open GitHub search for open PRs by author team or review-requested team (defaults to `team-feature-flags`). |

#### Automated PR review

These orchestrate Claude Code reviews of pull requests. They power the `review-all-prs` LaunchAgent.

| Script | Purpose |
| ------ | ------- |
| [`review-all-prs.sh`](bin/review-all-prs.sh) | Find PRs awaiting your review in a GitHub org using the GraphQL API. Filters out PRs you've already reviewed. |
| [`run-pr-reviews.sh`](bin/run-pr-reviews.sh) | Take a list of PRs and run `/review-code` against each one with budget and rate limits. |
| [`review-all-prs-service.sh`](bin/review-all-prs-service.sh) | Manage the `review-all-prs` macOS LaunchAgent (install, start, stop, logs, run). |
| [`recent-reviews.sh`](bin/recent-reviews.sh) | Show recent PR review activity from session state files. |
| [`seed-pr-failures.sh`](bin/seed-pr-failures.sh) | Rebuild the persistent PR-failure ledger from session history. |
| [`copilot-review-loop.sh`](bin/copilot-review-loop.sh) | Request Copilot reviews, fix legitimate issues, reply to others, push, repeat. |
| [`review-fix-loop.sh`](bin/review-fix-loop.sh) | Run the `/review-fix-cycle` skill in a loop with fresh Claude context per iteration. |

#### Disk and system

| Script | Purpose |
| ------ | ------- |
| [`check-disk-space`](bin/check-disk-space) | Disk space monitor with warning (85%) and critical (90%) macOS notifications. |
| [`disk-cleanup`](bin/disk-cleanup) | Modular cleanup orchestrator (Docker, Homebrew, Node, Python, Rust, Xcode caches). |
| [`kube-region`](bin/kube-region) | Switch `kubectl` context between PostHog environments with AWS SSO integration. |
| [`copy-html-to-clipboard.swift`](bin/copy-html-to-clipboard.swift) | Pipe HTML on stdin to the macOS clipboard as rich text. |
| [`set-defaults.sh`](bin/set-defaults.sh) | Apply macOS defaults from `macos/set-defaults.sh`. |
| [`dot`](bin/dot) | Run installers and apply settings; periodic refresh of the dotfiles environment. |

#### Claude Code session helpers

| Script | Purpose |
| ------ | ------- |
| [`claude-session`](bin/claude-session) | Manage tmux sessions for Claude Code (new, attach, list, kill, status). |
| [`claude-session-tokens`](bin/claude-session-tokens) | Read token usage from the current Claude Code session JSONL. |
| [`token-count`](bin/token-count) | Count tokens in a text file using `tiktoken` (cl100k_base) via uv's inline script deps. |

### Shell, git, and OS configuration

| Path | What's in it |
| ------ | ------------ |
| [`zsh/zshrc.symlink`](zsh/zshrc.symlink) | Interactive shell: oh-my-zsh, language managers (pyenv, rbenv, nvm, pnpm, direnv), PATH, helpers (`listening`, `killpid`). |
| [`zsh/zshenv.symlink`](zsh/zshenv.symlink) | Always-on environment: Homebrew, `~/.local/bin`, Cargo. |
| [`zsh/zprofile.symlink`](zsh/zprofile.symlink) | Login shells: .NET tools, OrbStack. |
| [`zsh/aliases.zsh`](zsh/aliases.zsh) | Aliases for disk tooling, PR review, `pytest-changes`. |
| [`zsh/claude-completion.zsh`](zsh/claude-completion.zsh) | Zsh tab completion for the `claude` CLI. |
| [`zsh/gt-completion.zsh`](zsh/gt-completion.zsh) | Zsh tab completion for Graphite (`gt`). |
| [`zsh/ssh-tmux.zsh`](zsh/ssh-tmux.zsh) | Auto-attach tmux for SSH sessions. |
| [`git/gitconfig.symlink`](git/gitconfig.symlink) | Base git config (aliases, signing, defaults). |
| [`git/gitconfig.aliases.symlink`](git/gitconfig.aliases.symlink) | Git aliases. |
| [`git/LaunchAgents/`](git/LaunchAgents) | macOS LaunchAgents (including the PR review service). |
| [`macos/set-defaults.sh`](macos/set-defaults.sh) | macOS defaults: Finder, Dock, screenshot location, etc. |
| [`homebrew/install.sh`](homebrew/install.sh) | Homebrew bootstrap. |

## Adopting pieces of this

You don't need to install the whole thing. A few common shapes:

- **Just the Claude skills/subagents**: copy individual directories from `ai/skills/` or `ai/agents/` into your own `~/.claude/skills/` or `~/.claude/agents/`. Most are self contained.
- **Just `tree-me`**: copy `bin/tree-me` onto your `PATH` and add `source <(tree-me shellenv)` to your shell rc.
- **Just the PR review scripts**: they depend on `bin/lib/*.sh` helpers; copy `bin/lib/` alongside whichever scripts you want.

A handful of skills and scripts are PostHog-specific (`metabase-prod-query`, `ops-report`, `sprint-planning`, `kube-region`, `triage-feature-flags`). The rest are general.
