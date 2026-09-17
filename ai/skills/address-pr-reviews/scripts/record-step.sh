#!/usr/bin/env bash
# Record that this skill finished a pass.
#
# Usage: record-step.sh <step>
#
# RAN_BRANCH names the branch to record against. A detached checkout needs it.
#
# The record feeds the `ran` report and `go`'s resume. Both read the state directory
# under $HOME on the developer's own machine. A cloud agent run unpacks this skill
# into a sandbox that has no dotfiles clone. That sandbox discards its state directory
# when the run ends, so an absent clone is a skip rather than a failure.
#
# The skip tests for the clone directory, not for the helper inside it. A clone that
# is present but has lost the helper is a broken install, and every pass would
# otherwise go unrecorded in silence until `go` re-invoked this skill forever. Every
# other failure propagates for the same reason. log-step-done.sh rejects a step name
# that is not in its table, and a typo there must not read as a pass.

set -euo pipefail

DOTFILES_DIR="${DOTFILES_DIR:-$HOME/.dotfiles}"
helper="${DOTFILES_DIR}/ai/bin/log-step-done.sh"

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <step>" >&2
  exit 1
fi

if [[ ! -d "$DOTFILES_DIR" ]]; then
  echo "record-step: no dotfiles clone at ${DOTFILES_DIR}, so this pass goes unrecorded." >&2
  exit 0
fi

exec "$helper" "$1"
