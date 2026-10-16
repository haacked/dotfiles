#!/bin/bash
# Trunk merge-queue comment bodies shared by test-git-pr.sh and
# test-claude-sessions.sh, in the wording that Trunk posts them.
#
# Usage: source "$SCRIPT_DIR/test-trunk-comments.sh"

# shellcheck disable=SC2034 # The sourcing suites use these.

TRUNK_CONTROL='<!-- Trunk Merge -->
Merging to `master` in this repository is managed by Trunk.'
TRUNK_ANALYTICS='<!-- Trunk Test Analytics -->'
TRUNK_SUBMITTED='✨ Submitted to Merge by Phil Haack (@haacked). It will be added to the merge queue once all branch protection rules pass. See more details [here](https://app.trunk.io/x).'
TRUNK_STACK_SUBMITTED='✨ Stack submitted to Merge by Phil Haack (@haacked). It will be added to the merge queue once all branch protection rules pass. See more details [here](https://app.trunk.io/x).'
# Trunk posts a stack submission as a new comment under its marker.
TRUNK_STACK_POSTED="<!-- Trunk Merge -->
$TRUNK_STACK_SUBMITTED"
TRUNK_IN_STACK='This pull request is queued for merge as part of [13](https://www.github.com/haacked/dotfiles/pull/13), which will merge [9](https://www.github.com/haacked/dotfiles/pull/9), [13](https://www.github.com/haacked/dotfiles/pull/13).'
TRUNK_STACK_FAILED='Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) failed testing in the merge queue. Please investigate the failure and re-submit the stack.'
TRUNK_STACK_CANCELLED='Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) was cancelled: the stack changed after it was queued.'
TRUNK_STACK_RETURNED="Stacked PR [13](https://www.github.com/haacked/dotfiles/pull/13) was returned to waiting: this pull request was pushed to. Rebase the stack onto this pull request's new head and the stacked merge re-enters the queue on its own."
TRUNK_WAITING='⏳ Stack waiting to start tests on this stack because a batch ([#106996](https://www.github.com/haacked/dotfiles/pull/106996)) ahead of it failed tests - [details](https://app.trunk.io/x).'
TRUNK_TESTING='🧪 Running tests on this stack (testing on PR [#12](https://www.github.com/haacked/dotfiles/pull/12)) - [details](https://app.trunk.io/x).'
TRUNK_PASSED='👍 Pull request will be merged soon because it has passed required tests (tested on PR [#12](https://www.github.com/haacked/dotfiles/pull/12)) - [details](https://app.trunk.io/x).'
TRUNK_FAILED='❌ This pull request was removed from the merge queue because it failed tests. PR [#12](https://github.com/haacked/dotfiles/pull/12) was used for testing. See more details [here](https://app.trunk.io/x).'
TRUNK_STALE_TIMEOUT='🚫 This pull request was removed from the merge queue because it was waiting to become mergeable for too long (for example: missing required approvals or checks, or a merge conflict). Submit it again once it is ready.'
TRUNK_CHECK_FAILING='⚠️ The required check [`Visual regression tests pass`](https://github.com/haacked/dotfiles/actions/runs/1/job/2) (Failure) has failed. Pull request failed tests and is waiting for other pull requests to finish testing. PR [#12](https://www.github.com/haacked/dotfiles/pull/12) was used for testing. See more details [here](https://app.trunk.io/x).'
TRUNK_UNTESTED='❌ This pull request could not start testing because there was a merge conflict. See more details [here](https://app.trunk.io/x).
<!-- Start PR Submit Checkbox -->
- [ ] <!-- End PR Submit Checkbox -->To merge this pull request, check the box to the left or comment `/trunk merge` below.'
TRUNK_REENTERING='⏳ Re-entering the merge queue because it has passed tests on a bisection of its original batch - [details](https://app.trunk.io/x).'
TRUNK_CANCELLED='🛑 This pull request was cancelled and will not be merged.'
TRUNK_ALREADY_QUEUED='This PR is already queued as a stacked merge. Cancel it first to re-submit.'
TRUNK_ERROR='An error occurred while submitting your PR to the queue: `Something went wrong. Please try again`'
TRUNK_MERGED='😎 Merged successfully - [details](https://app.trunk.io/x).'
