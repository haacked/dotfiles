# haacked dotfiles

Your dotfiles are how you personalize your system. These are mine.

They're so personal I copied much of them from <https://github.com/holman/dotfiles> including the approach to install them.

## Install

On a brand-new Mac, run the one-liner. It installs the Xcode Command Line Tools (for git), clones this repo to `~/.dotfiles`, and runs `script/bootstrap`:

```sh
curl -fsSL https://raw.githubusercontent.com/haacked/dotfiles/main/install.sh | bash
```

Or, if you prefer to do it by hand (and git, via the Xcode Command Line Tools, is already installed):

```sh
git clone https://github.com/haacked/dotfiles.git ~/.dotfiles
cd ~/.dotfiles
script/bootstrap
```

Either way, bootstrap symlinks the appropriate files in `.dotfiles` into your home directory. Everything is configured and tweaked within `~/.dotfiles`. The installer points the `origin` remote at SSH, so add an SSH key to GitHub before you push.

The main file you'll want to change right off the bat is `zsh/zshrc.symlink`, which sets up a few paths that'll be different on your particular machine.

`dot` is a simple script that installs some dependencies, sets sane macOS defaults, and so on. Tweak this script, and occasionally run `dot` from time to time to keep your environment fresh and up to date. You can find this script in `bin/`.

### ZSH

`~/.zshrc` is managed by this repo via `zsh/zshrc.symlink`. Running `script/bootstrap` creates the symlink automatically.

### AI tooling

The `ai/` directory contains shared Claude Code and Codex configuration: global instructions, subagents, skills, model-tier adapters, and helper hooks. Run `ai/install.sh` to install both platforms, or pass `--claude-only` or `--codex-only`. See [`ai/README.md`](ai/README.md) for details.

## Inventory

This repo ships a fair amount of tooling: shared AI skills and subagents, shell scripts, git helpers, and macOS utilities. The tables below are an organized inventory so you (or a colleague) can find what's useful.

### AI skills

Skills live in [`ai/skills/`](ai/skills). The installer symlinks the same directories into `~/.claude/skills/` and `~/.agents/skills/`, so both platforms use one canonical source, minus the Codex exclusions in `ai/codex/excluded-skills.txt`. [`ai/codex/skills/`](ai/codex/skills) holds the few skills only Codex gets, because Claude already bundles its own under the same name. Each skill is a self-contained directory with a `SKILL.md` and any supporting scripts.

| Skill | What it does |
| ------- | ------------ |
| [`address-pr-reviews`](ai/skills/address-pr-reviews) | Evaluate unresolved PR review comments from any reviewer, fix legitimate issues, reply to dismissed ones. |
| [`analyze-permissions`](ai/skills/analyze-permissions) | Analyze accumulated Claude Code permissions and suggest smart wildcard patterns. |
| [`babysit-prs`](ai/skills/babysit-prs) | One sweep over every open PR: CI and merge-queue state, new review comments, fix and push. |
| [`ci-monitor`](ai/skills/ci-monitor) | Monitor CI checks after pushing, distinguish flaky from real failures, auto-fix. |
| [`comment-cleanup`](ai/skills/comment-cleanup) | Delete and tighten code comments after they are written, cutting the survivors to one fact each. |
| [`commit`](ai/skills/commit) | Commit staged/unstaged changes with a well-crafted commit message. |
| [`create-pr`](ai/skills/create-pr) | Create or update a GitHub PR with automatic template detection and filling. |
| [`explain-open`](ai/skills/explain-open) | Explain open or skipped code-review items in plain English with impact analysis and a recommendation. |
| [`followup`](ai/skills/followup) | Capture a follow-up item mid-session, list open items, close one, or run a review pass. |
| [`github-pr-operations`](ai/skills/github-pr-operations) | Reference for GitHub PR review endpoints and resolving review threads via `gh`. |
| [`go`](ai/skills/go) | Plan, implement, and review a task end to end: review-code and ReviewHog in parallel, CI watched to green, open items explained. |
| [`handoff`](ai/skills/handoff) | Write or resume a handoff document so the next agent session can pick up the current work. |
| [`metabase-prod-query`](ai/skills/metabase-prod-query) | Guarded workflow for querying PostHog production Metabase via `hogli metabase:*`. |
| [`note`](ai/skills/note) | Capture complex technical discoveries into structured, reusable notes. |
| [`ops-report`](ai/skills/ops-report) | Generate a 24-hour operational health report for a PostHog service via Grafana and Prometheus. |
| [`plain-writing`](ai/skills/plain-writing) | Write, rewrite, or review prose for other people in clear, direct English. |
| [`posthog-context`](ai/skills/posthog-context) | PostHog repo workflow, database access rules, production architecture notes, SDK repository locations. |
| [`quarterly-planning`](ai/skills/quarterly-planning) | Draft quarterly goals for a PostHog team, walking the HOGS framework from issues and strategy docs. |
| [`ran`](ai/skills/ran) | Show which workflow steps have run against this branch and which are missing or stale. |
| [`resolve-conflicts`](ai/skills/resolve-conflicts) | Resolve git conflicts with mergiraf structural merging, lock file handling, stacked PR dedup. |
| [`review-fix-cycle`](ai/skills/review-fix-cycle) | One review, fix, simplify, clean comments, commit iteration. |
| [`simplify`](ai/codex/skills/simplify) | Simplify recently changed code for clarity and maintainability without changing behavior. Codex only; Claude bundles its own. |
| [`sprint-planning`](ai/skills/sprint-planning) | Bi-weekly sprint planning updates for the Feature Flags Platform team. |
| [`squash`](ai/skills/squash) | Squash each contributor's run of contiguous commits on the branch into one, preserving authorship. |
| [`standup`](ai/skills/standup) | Generate standup notes from your recent GitHub PR activity. |
| [`support`](ai/skills/support) | Support hero workflow: start ticket investigations, find prior notes, generate weekly highlights. |
| [`test-plan`](ai/skills/test-plan) | Generate a manual test plan checklist focused on scenarios uncovered by existing tests. |
| [`triage-issues`](ai/skills/triage-issues) | Identify unlabeled GitHub issues that may belong to a specific team. |
| [`vault`](ai/skills/vault) | Operate the notes vault knowledge loop: ingest raw sources into interlinked wiki pages, lint vault health, consolidate duplicate pages, show the backlog. |
| [`wait-for-pr-reviews`](ai/skills/wait-for-pr-reviews) | Wait for in-flight PR reviews, chaining address-pr-reviews before and after the wait. |

The `squash` command lives at [`ai/commands/squash.md`](ai/commands/squash.md): squash developer commits on the current branch into one while preserving CI snapshot commits.

### AI subagents

Subagents live in [`ai/agents/`](ai/agents). Claude uses the Markdown definitions directly; the Codex installer renders equivalent TOML definitions into `~/.codex/agents/` with mapped models and reasoning effort.

| Agent | When to use it |
| ------- | -------------- |
| [`bug-root-cause-analyzer`](ai/agents/bug-root-cause-analyzer.md) | Failing tests, intermittent bugs, or environment-specific defects that need a systematic investigation. |
| [`code-reviewer`](ai/agents/code-reviewer.md) | Pre-commit correctness, security, and guideline review (use the `simplify` skill for readability). |
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

These scripts run pull request reviews through Claude Code or Codex. The `review-all-prs` LaunchAgent uses Codex, reviews only PRs from `team-feature-flags`, starts one PR per hourly run, and allows two attempts per calendar day. Failed reviews count toward the daily limit.

Before starting or reinstalling the LaunchAgent, install the Codex CLI and run `codex login`. Existing service installations that only configured Claude will stop at the runner's authentication check until Codex is available.

| Script | Purpose |
| ------ | ------- |
| [`review-all-prs.sh`](bin/review-all-prs.sh) | Find PRs awaiting your review in a GitHub org using the GraphQL API. `--author-team` limits every result source to current team members. The script filters out settled reviews and sorts by priority: `--priority-team` authors, flags-scoped titles, then the rest. |
| [`run-pr-reviews.sh`](bin/run-pr-reviews.sh) | Take a list of PRs and run the `review-code` skill through `--engine claude` or `--engine codex`. It supports per-run and daily attempt limits, review timeouts, and engine usage-limit detection. |
| [`review-all-prs-service.sh`](bin/review-all-prs-service.sh) | Manage the `review-all-prs` macOS LaunchAgent (install, start, stop, logs, run). |
| [`recent-reviews.sh`](bin/recent-reviews.sh) | Show recent PR review activity from session state files. |
| [`seed-pr-failures.sh`](bin/seed-pr-failures.sh) | Rebuild the persistent PR-failure ledger from session history. |
| [`copilot-review-loop.sh`](bin/copilot-review-loop.sh) | Request Copilot reviews, fix legitimate issues, reply to and resolve Copilot threads, gather drafted replies to human reviewers for you to post, push, repeat. |
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

- **Just the AI skills/subagents**: copy individual skill directories into `~/.claude/skills/` or `~/.agents/skills/`. A skill refers to its own scripts relative to its directory, so it works wherever you put it. Some skills also call a repo binary or another skill, and those references are absolute `~/.dotfiles/…` paths that need this whole repo cloned there. To tell which kind you have, `grep -r '~/.dotfiles' <skill-dir>`: no matches means it stands alone. Claude agent definitions go in `~/.claude/agents/`; use `ai/bin/render-codex-agents.py` to produce Codex agent TOML files.
- **Just `tree-me`**: copy `bin/tree-me` onto your `PATH` and add `source <(tree-me shellenv)` to your shell rc.
- **Just the PR review scripts**: they depend on `bin/lib/*.sh` helpers; copy `bin/lib/` alongside whichever scripts you want.

A handful of skills and scripts are PostHog-specific (`metabase-prod-query`, `ops-report`, `posthog-context`, `quarterly-planning`, `sprint-planning`, `kube-region`, `triage-feature-flags`). The rest are general.
