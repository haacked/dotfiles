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
# The clone is found from this script's own location rather than a fixed path, so a
# clone checked out anywhere still records. `pwd -P` resolves the symlink the installer
# leaves in the agent's skills directory, so the walk lands inside the clone. In a
# sandbox the same walk lands outside the unpacked folder, where the .git test fails
# and the pass is skipped. DOTFILES_DIR overrides the search.
#
# A clone that is present but has lost the helper is a broken install, and every pass
# would otherwise go unrecorded in silence until `go` re-invoked this skill forever.
# That case fails rather than skipping, as does every other failure. log-step-done.sh
# rejects a step name that is not in its table, and a typo there must not read as a pass.

set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $(basename "$0") <step>" >&2
  exit 1
fi

find_clone() {
  local script_dir root
  script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P) || return 1
  root=$(cd "${script_dir}/../../../.." 2>/dev/null && pwd -P) || return 1
  [[ -e "${root}/.git" ]] || return 1
  printf '%s\n' "$root"
}

if [[ -n "${DOTFILES_DIR:-}" ]]; then
  clone="$DOTFILES_DIR"
  if [[ ! -d "$clone" ]]; then
    echo "record-step: no dotfiles clone at ${clone}, so this pass goes unrecorded." >&2
    exit 0
  fi
elif ! clone=$(find_clone); then
  echo "record-step: no dotfiles clone above $(dirname "$0"), so this pass goes unrecorded." >&2
  exit 0
fi

exec "${clone}/ai/bin/log-step-done.sh" "$1"
