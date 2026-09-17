#!/usr/bin/env bash
# sync-portable-skills.sh is the only thing standing between a helper edited under
# bin/ and a skill folder that still ships the old text, and CI only ever runs it
# against a tree CI itself keeps in sync. Every branch that reports a problem is
# therefore dead in CI. These cases drive the real script over a copied tree so the
# reporting paths run.
#
# REPO_ROOT comes from the script's own location, so a copy of ai/ and bin/ under a
# temporary directory is a complete tree as far as the script is concerned.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

passes=0
failures=0

pass() { passes=$((passes + 1)); }

fail() {
	echo "FAIL: $1"
	if [ $# -gt 1 ]; then
		printf '  %s\n' "$2"
	fi
	failures=$((failures + 1))
}

# Sets $out and $status from a run of the script under test.
run_sync() {
	status=0
	out=$("$sync" "$@" 2>&1) || status=$?
}

tree=$(mktemp -d)
trap 'rm -rf "$tree"' EXIT
cp -R "${REPO_ROOT}/ai" "${REPO_ROOT}/bin" "$tree/"
sync="${tree}/ai/bin/sync-portable-skills.sh"
copy='ai/skills/address-pr-reviews/scripts/lib/copilot.sh'

if "$sync" --check >/dev/null 2>&1; then
	pass
else
	fail 'accept a tree that is in sync'
fi

printf '\n# drift\n' >>"${tree}/${copy}"
run_sync --check
if [ "$status" -ne 0 ]; then pass; else fail 'reject a stale copy'; fi
case "$out" in
*"$copy"*) pass ;;
*) fail 'name the stale copy' "$out" ;;
esac

"$sync" >/dev/null 2>&1
if "$sync" --check >/dev/null 2>&1; then
	pass
else
	fail 'write mode refreshes the stale copy'
fi

# A copy that lost its executable bit runs as a plain file in the sandbox, which is
# the same outage as a missing copy and reports the same way.
chmod -x "${tree}/${copy}"
if "$sync" --check >/dev/null 2>&1; then
	fail 'reject a copy that lost its executable bit'
else
	pass
fi
"$sync" >/dev/null 2>&1

rm "${tree}/${copy}"
run_sync --check
if [ "$status" -ne 0 ]; then pass; else fail 'reject a missing copy'; fi
"$sync" >/dev/null 2>&1

# Both modes validate every source before either writes anything. Without that pass a
# deleted source reads as a stale copy, and the sync the message names dies partway.
rm "${tree}/bin/lib/fs.sh"
run_sync
if [ "$status" -ne 0 ]; then pass; else fail 'refuse to write when a source is gone'; fi
case "$out" in
*'Missing helper source: bin/lib/fs.sh'*) pass ;;
*) fail 'name the missing source' "$out" ;;
esac
if cmp -s "${REPO_ROOT}/bin/lib/github.sh" "${tree}/ai/skills/address-pr-reviews/scripts/lib/github.sh"; then
	pass
else
	fail 'leave every copy untouched when a source is gone'
fi
cp "${REPO_ROOT}/bin/lib/fs.sh" "${tree}/bin/lib/fs.sh"

# A renamed or deleted table row leaves its copy behind. Walking the table cannot see
# that file, so the folder is walked against both tables instead.
orphan='ai/skills/address-pr-reviews/scripts/lib/orphan.sh'
cp "${tree}/${copy}" "${tree}/${orphan}"
run_sync --check
if [ "$status" -ne 0 ]; then pass; else fail 'reject an undeclared file'; fi
case "$out" in
*"$orphan"*) pass ;;
*) fail 'name the undeclared file' "$out" ;;
esac

"$sync" >/dev/null 2>&1
if [ -e "${tree}/${orphan}" ]; then
	fail 'write mode deletes the undeclared file'
else
	pass
fi
if "$sync" --check >/dev/null 2>&1; then
	pass
else
	fail 'accept the tree again once the undeclared file is gone'
fi

echo "Passed: ${passes}, Failed: ${failures}"
[ "$failures" -eq 0 ]
