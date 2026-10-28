#!/bin/bash
# Tests for bin/cleanup-modules/orbstack.sh.
#
# Usage: test-cleanup-orbstack.sh
#
# Builds an OrbStack data directory under a fake HOME and drives the module.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/lib/test-helpers.sh
source "$SCRIPT_DIR/test-helpers.sh"
# shellcheck source=bin/cleanup-modules/orbstack.sh
source "$SCRIPT_DIR/../cleanup-modules/orbstack.sh"

log_message() { :; }
run_cleanup() {
  [ "$DRY_RUN" = true ] && return 0
  eval "$2" || echo "Failed: $1"
}
DRY_RUN=false

FAKE_HOME=$(mktemp -d)
trap 'rm -rf "$FAKE_HOME"' EXIT
HOME="$FAKE_HOME"
DATA="$FAKE_HOME/Library/Group Containers/TEAMID.dev.orbstack/data"
mkdir -p "$DATA"

touch "$DATA/data.img.raw.corrupt"
cleanup_orbstack aggressive
assert "keeps the corrupt image when no live image exists" test -f "$DATA/data.img.raw.corrupt"

touch "$DATA/data.img.raw" "$DATA/swap.img"
ln -s data.img.raw "$DATA/data.img"
DRY_RUN=true cleanup_orbstack aggressive
assert "dry run keeps the corrupt image" test -f "$DATA/data.img.raw.corrupt"

cleanup_orbstack conservative
assert "conservative mode keeps the corrupt image" test -f "$DATA/data.img.raw.corrupt"

cleanup_orbstack aggressive
assert_not "removes the corrupt image once a live image exists" test -e "$DATA/data.img.raw.corrupt"
assert "keeps the live image" test -f "$DATA/data.img.raw"
assert "keeps the swap image" test -f "$DATA/swap.img"

cleanup_orbstack aggressive
assert "runs cleanly with nothing to remove" test -f "$DATA/data.img.raw"

print_results
