# pr-followups

`SKILL.md` describes the skill and its checks. This file shows how to run its Slack mode on a schedule.

## Scheduling

The working example is the launchd job in this repo. It runs Slack mode every weekday at 07:45:

```bash
~/.dotfiles/bin/pr-followups-service.sh install   # load the schedule
~/.dotfiles/bin/pr-followups-service.sh run       # run once now, in the foreground
~/.dotfiles/bin/pr-followups-service.sh status    # show the schedule and the last run
~/.dotfiles/bin/pr-followups-service.sh logs      # follow the log
~/.dotfiles/bin/pr-followups-service.sh resume    # reopen the last run's session
```

`bin/pr-followups-run` starts `claude` without a terminal and allows exactly four tools: `ToolSearch`, `scripts/pr-followups.py scan`, `scripts/pr-followups.py record`, and the Slack send tool. PR titles come from other people, so the run must not get broader tools. That rules out a plain cron line such as `claude -p "/pr-followups --format slack" --permission-mode bypassPermissions`: a PR title could then steer a run that may use any tool. A tool allowlist also stops `claude` from loading skills, so the worker pastes `SKILL.md` into its prompt.

To run it inside a Switchboard session that is already open, schedule the prompt there. That session's own permission prompts still apply:

```bash
sb schedule <session> --every 24h "/pr-followups --format slack"
```
