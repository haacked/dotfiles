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

run_sync --check
if [ "$status" -eq 0 ]; then pass; else fail 'accept a tree that is in sync' "$out"; fi

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
# that file, so the sync walks the whole skill folder against both tables instead. That
# covers a vendored reference the same way it covers a script.
assert_orphan_reported() { # path relative to the skill directory
	local orphan="ai/skills/address-pr-reviews/$1"
	cp "${tree}/${copy}" "${tree}/${orphan}"
	run_sync --check
	if [ "$status" -ne 0 ]; then pass; else fail "reject the undeclared $1"; fi
	case "$out" in
	*"$orphan"*) pass ;;
	*) fail "name the undeclared $1" "$out" ;;
	esac

	"$sync" >/dev/null 2>&1
	if [ -e "${tree}/${orphan}" ]; then fail "write mode deletes $1"; else pass; fi
	run_sync --check
	if [ "$status" -eq 0 ]; then pass; else fail "accept the tree again once $1 is gone" "$out"; fi
}

assert_orphan_reported 'scripts/lib/orphan.sh'
assert_orphan_reported 'references/orphan.md'

# Every other pass starts from the table, so a file added to a vendored skill would
# otherwise reach no copy with CI still green.
unvendored="${tree}/ai/skills/plain-writing/references/technical.md"
touch "$unvendored"
run_sync --check
if [ "$status" -ne 0 ]; then pass; else fail 'reject a source file no row vendors'; fi
case "$out" in
*'ai/skills/plain-writing/references/technical.md'*) pass ;;
*) fail 'name the source file no row vendors' "$out" ;;
esac

# Only the destination names the source skill. A row that breaks that mirror points the
# source walk at a directory that is not there, where it reads nothing and exits 0, so
# the mirror is checked before the walk runs.
sed -i.bak 's|:references/plain-writing/|:references/pw/|' "${tree}/ai/helpers/portable-skills.sh"
mv "${tree}/ai/skills/address-pr-reviews/references/plain-writing" \
	"${tree}/ai/skills/address-pr-reviews/references/pw"
run_sync --check
if [ "$status" -ne 0 ]; then pass; else fail 'reject a row that breaks the references mirror'; fi
case "$out" in
*'must come from ai/skills/pw/SKILL.md'*) pass ;;
*) fail 'name the mirror the row breaks' "$out" ;;
esac
mv "${tree}/ai/helpers/portable-skills.sh.bak" "${tree}/ai/helpers/portable-skills.sh"
mv "${tree}/ai/skills/address-pr-reviews/references/pw" \
	"${tree}/ai/skills/address-pr-reviews/references/plain-writing"

# The source skill's own tests and its __pycache__ never travel, so neither reads as a
# file the bundle is missing.
rm "$unvendored"
mkdir -p "${tree}/ai/skills/plain-writing/scripts/__pycache__"
touch "${tree}/ai/skills/plain-writing/scripts/__pycache__/plain-writing-lint.pyc" \
	"${tree}/ai/skills/plain-writing/scripts/tests/test_extra.py"
run_sync --check
if [ "$status" -eq 0 ]; then pass; else fail 'skip a source test and __pycache__' "$out"; fi

echo "Passed: ${passes}, Failed: ${failures}"
[ "$failures" -eq 0 ]
