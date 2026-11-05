#!/usr/bin/env bash
# Tests for script/test, the runner that CI uses to find and run every test script.
#
# Each case builds a fixture git repository and drives a copy of the runner over it.
# The copy lives in a scratch repository that holds no tests. A runner that ignores
# its directory argument therefore scans that empty repository, not this one.
# Running this repository's suite from here would run this file again.
#
# Fixture tests append their repo path to a log file. A test that ran has a line in
# the log. The cases assert on what ran rather than on the runner's output format.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
RUNNER_SRC="${REPO_ROOT}/script/test"

# shellcheck source=bin/lib/test-helpers.sh
source "${REPO_ROOT}/bin/lib/test-helpers.sh"

# macOS puts mktemp under the /var symlink. The symlink case below needs the
# physical path to build its own link.
TEST_ROOT=$(cd "$(mktemp -d)" && pwd -P) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

# A developer's global config can set core.quotePath=false, which hides the quoting
# that git applies to non-ASCII paths on CI.
export GIT_CONFIG_GLOBAL=/dev/null
export GIT_CONFIG_NOSYSTEM=1

RUNNER_REPO="${TEST_ROOT}/runner-repo"
RUNNER="${RUNNER_REPO}/script/test"
mkdir -p "${RUNNER_REPO}/script"
git -C "$RUNNER_REPO" init -q
cp -p "$RUNNER_SRC" "$RUNNER"

# Creates an empty fixture repository named $1 and sets FIXTURE and LOG.
new_fixture() {
	FIXTURE="${TEST_ROOT}/$1"
	LOG="${TEST_ROOT}/$1.log"
	mkdir -p "$FIXTURE"
	git -C "$FIXTURE" init -q
	git -C "$FIXTURE" config core.quotePath true
	begin_scenario
}

# Clears the log and records the failure count, so end_scenario can tell whether
# this scenario failed.
begin_scenario() {
	: >"$LOG"
	scenario_failures=$failures
}

# Writes an executable bash test at fixture path $1. It prints a line holding the
# <<<RAN marker, logs its path, and then runs $2, which defaults to "exit 0".
add_sh_test() {
	local path="$1" finish="${2:-exit 0}"
	mkdir -p "$(dirname "${FIXTURE}/${path}")"
	cat >"${FIXTURE}/${path}" <<EOF
#!/bin/bash
echo "<<<RAN ${path}>>>"
printf '%s\n' '${path}' >>'${LOG}'
${finish}
EOF
	chmod +x "${FIXTURE}/${path}"
}

# Writes a pytest test at fixture path $1 that logs its path. With $2 set to
# "fail", the test function fails after it logs. The file has no __main__ block.
# Plain python3 therefore logs nothing and exits 0.
add_py_test() {
	local path="$1" outcome="pass"
	[[ "${2:-}" == fail ]] && outcome="assert False, 'fixture failure'"
	mkdir -p "$(dirname "${FIXTURE}/${path}")"
	cat >"${FIXTURE}/${path}" <<EOF
def test_records_run():
    with open('${LOG}', 'a') as log:
        log.write('${path}\n')
    ${outcome}
EOF
}

# Stages every file in the fixture that .gitignore does not ignore.
track_all() {
	git -C "$FIXTURE" add -A
}

# Runs "$2..." from directory $1 with stdin from /dev/null and stderr merged into
# stdout. Sets OUT to the output and STATUS to the exit status, or 124 on timeout.
run_in() {
	local cwd="$1"
	shift
	STATUS=0
	# shellcheck disable=SC2016 # The inner bash expands its own positional parameters.
	OUT=$(run_bounded 120 bash -c 'cd "$1" && shift && exec "$@" </dev/null 2>&1' _ "$cwd" "$@") || STATUS=$?
}

run_runner() {
	local cwd="$1"
	shift
	run_in "$cwd" "$RUNNER" "$@"
}

ran() { grep -qxF -- "$1" "$LOG"; }
ran_once() { [[ "$(grep -cxF -- "$1" "$LOG")" -eq 1 ]]; }
status_is_zero() { [[ "$STATUS" -eq 0 ]]; }
status_is_failure() { [[ "$STATUS" -ne 0 && "$STATUS" -ne 124 ]]; }

# Succeeds when $1 appears in the runner output after the last line that a fixture
# test printed. Those lines carry the <<<RAN marker. Anything after the last of
# them comes from the runner once every test has finished.
summary_names() {
	printf '%s\n' "$OUT" |
		awk '/<<<RAN /{ buf = ""; next } { buf = buf $0 "\n" } END { printf "%s", buf }' |
		grep -qF -- "$1"
}

# Prints the runner output once when any assertion in the current scenario failed.
end_scenario() {
	if ((failures > scenario_failures)); then
		echo "  runner exit status: $STATUS"
		printf '%s\n' "$OUT" | head -60 | sed 's/^/  | /'
	fi
}

assert "script/test exists and is executable" test -x "$RUNNER_SRC"

new_fixture discovery
matching=(
	test-root.sh
	ai/tests/test-in-tests-dir.sh
	ai/skills/resolve-conflicts/scripts/test-next-to-script.sh
	deep/a/b/c/test-deep.sh
)
for path in "${matching[@]}"; do add_sh_test "$path"; done
matching_py=(
	ai/skills/go/scripts/tests/test_in_tests_dir.py
	ai/skills/sprint-planning/scripts/test_next_to_script.py
)
for path in "${matching_py[@]}"; do add_py_test "$path"; done
non_matching=(
	foo-test.sh
	mytest-x.sh
	ai/atest-x.sh
	test_underscore.sh
	testfoo.sh
	test-x.sh.bak
	test-x.bash
	Test-upper.sh
	test-dir/helper.sh
	ai/test-dir/also-helper.sh
)
for path in "${non_matching[@]}"; do add_sh_test "$path" 'exit 1'; done
non_matching_py=(
	test-dash.py
	tests/helper_test.py
	test_x.py.orig
	testx.py
)
for path in "${non_matching_py[@]}"; do add_py_test "$path" fail; done
printf 'ignored/\nnode_modules/\n' >"${FIXTURE}/.gitignore"
ignored=(ignored/test-ignored.sh node_modules/pkg/test-vendored.sh)
for path in "${ignored[@]}"; do add_sh_test "$path" 'exit 1'; done
track_all
untracked=(untracked/test-untracked.sh)
untracked_py=(untracked/test_untracked.py)
add_sh_test "${untracked[0]}"
add_py_test "${untracked_py[0]}"

run_runner "$TEST_ROOT" "$FIXTURE"

assert "discovery: exits 0 when every test passes" status_is_zero
for path in "${matching[@]}" "${matching_py[@]}" "${untracked[@]}" "${untracked_py[@]}"; do
	assert "discovery: runs $path exactly once" ran_once "$path"
done
for path in "${non_matching[@]}" "${non_matching_py[@]}"; do
	assert_not "discovery: skips $path, which does not match test-*.sh or test_*.py" ran "$path"
done
for path in "${ignored[@]}"; do
	assert_not "discovery: skips $path, which .gitignore ignores" ran "$path"
done
end_scenario

# git ls-files lists an unmerged path once for each index stage.
new_fixture conflict
fixture_git() { git -C "$FIXTURE" -c user.email=t@example.com -c user.name=t -c commit.gpgsign=false "$@"; }
add_sh_test test-conflicted.sh
track_all
fixture_git commit -qm base
fixture_git checkout -qb other
echo '# other' >>"${FIXTURE}/test-conflicted.sh"
fixture_git commit -qam other
fixture_git checkout -q -
echo '# mine' >>"${FIXTURE}/test-conflicted.sh"
fixture_git commit -qam mine
fixture_git merge -q other >/dev/null 2>&1
# The ours side has no conflict markers, so the test still runs. The unmerged
# index stages stay until git add.
fixture_git checkout --ours test-conflicted.sh

run_runner "$TEST_ROOT" "$FIXTURE"

assert "conflict: runs a test with unmerged index entries exactly once" ran_once test-conflicted.sh
end_scenario

new_fixture interpreters
# Not executable and no shebang: running it directly fails with permission denied.
mkdir -p "${FIXTURE}/plain"
cat >"${FIXTURE}/plain/test-no-exec-bit.sh" <<EOF
if [[ -n "\${BASH_VERSION:-}" ]]; then printf '%s\n' 'plain/test-no-exec-bit.sh' >>'${LOG}'; fi
EOF
chmod 644 "${FIXTURE}/plain/test-no-exec-bit.sh"
# A /bin/sh shebang over bash syntax: on Ubuntu, /bin/sh is dash, which has no [[.
cat >"${FIXTURE}/plain/test-sh-shebang.sh" <<EOF
#!/bin/sh
if [[ -n "\${BASH_VERSION:-}" ]]; then printf '%s\n' 'plain/test-sh-shebang.sh' >>'${LOG}'; fi
EOF
chmod +x "${FIXTURE}/plain/test-sh-shebang.sh"
add_py_test py/test_needs_pytest.py
track_all

run_runner "$TEST_ROOT" "$FIXTURE"

assert "interpreters: exits 0 when every test passes" status_is_zero
assert "interpreters: runs a shell test that lacks the executable bit with bash" ran plain/test-no-exec-bit.sh
assert "interpreters: runs a shell test with bash despite a /bin/sh shebang" ran plain/test-sh-shebang.sh
assert "interpreters: runs a Python test with pytest, which calls test functions" ran py/test_needs_pytest.py
end_scenario

new_fixture failures
add_sh_test a/test-fails-first.sh 'exit 1'
add_sh_test b/test-passes-early.sh
add_sh_test f/test-killed.sh 'kill -KILL $$'
add_py_test py/test_fails.py fail
add_sh_test z/test-passes-last.sh
track_all
failing=(a/test-fails-first.sh f/test-killed.sh py/test_fails.py)
passing=(b/test-passes-early.sh z/test-passes-last.sh)

run_runner "$TEST_ROOT" "$FIXTURE"

assert "failures: exits non-zero when any test fails" status_is_failure
for path in "${failing[@]}" "${passing[@]}"; do
	assert "failures: runs $path even though other tests fail" ran "$path"
done
for path in "${failing[@]}"; do
	assert "failures: the summary names $path" summary_names "$path"
done
end_scenario

# Each non-zero status on its own fails the run.
for finish in 'exit 1' 'kill -KILL $$'; do
	new_fixture "single-failure-$(printf '%s' "$finish" | tr -c 'a-zA-Z0-9' '-')"
	add_sh_test test-passes.sh
	add_sh_test test-fails.sh "$finish"
	track_all

	run_runner "$TEST_ROOT" "$FIXTURE"

	assert "failures: a test that ends with '$finish' fails the run" status_is_failure
	end_scenario
done

new_fixture single-python-failure
add_sh_test test-passes.sh
add_py_test test_fails.py fail
track_all

run_runner "$TEST_ROOT" "$FIXTURE"

assert "failures: a failing pytest test fails the run" status_is_failure
end_scenario

new_fixture stdin
add_sh_test a/test-reads-stdin.sh 'cat >/dev/null; exit 0'
add_sh_test b/test-after-reader.sh
add_py_test d/test_after_reader.py
track_all

run_runner "$TEST_ROOT" "$FIXTURE"

assert "stdin: exits 0 when every test passes" status_is_zero
for path in a/test-reads-stdin.sh b/test-after-reader.sh d/test_after_reader.py; do
	assert "stdin: runs $path" ran "$path"
done
end_scenario

# git quotes non-ASCII paths in ls-files output unless core.quotePath is false.
new_fixture special-paths
add_sh_test "with space/test-has space.sh"
add_sh_test "café/test-unicode.sh"
add_py_test "café/test_unicode.py"
add_sh_test "naïve/test-unicode-fails.sh" 'exit 1'
add_sh_test "with space/test-space fails.sh" 'exit 1'
add_sh_test "zz/test-passes-last.sh"
track_all

run_runner "$TEST_ROOT" "$FIXTURE"

assert "special paths: exits non-zero when a test fails" status_is_failure
for path in "with space/test-has space.sh" "café/test-unicode.sh" "café/test_unicode.py" "naïve/test-unicode-fails.sh" "with space/test-space fails.sh"; do
	assert "special paths: runs $path" ran "$path"
done
assert "special paths: the summary names naïve/test-unicode-fails.sh unquoted" summary_names "naïve/test-unicode-fails.sh"
assert "special paths: the summary names a failing test whose path has a space" summary_names "with space/test-space fails.sh"
end_scenario

new_fixture exclusions
excluded=(bin/lib/test-helpers.sh bin/lib/test-triage-stub.sh bin/lib/test-trunk-comments.sh)
for path in "${excluded[@]}"; do add_sh_test "$path" 'exit 1'; done
add_sh_test bin/lib/test-real.sh
add_sh_test bin/lib/test-helpers-extra.sh
add_sh_test other/test-helpers.sh
add_sh_test vendor/bin/lib/test-helpers.sh
add_sh_test vendor/bin/lib/test-real.sh
track_all
ln -s "$FIXTURE" "${TEST_ROOT}/exclusions-link"

run_runner "$TEST_ROOT" "$FIXTURE"

assert "exclusions (repo root): exits 0" status_is_zero
for path in "${excluded[@]}"; do
	assert_not "exclusions (repo root): skips $path" ran "$path"
done
for path in bin/lib/test-real.sh bin/lib/test-helpers-extra.sh other/test-helpers.sh vendor/bin/lib/test-helpers.sh; do
	assert "exclusions (repo root): runs $path, which no exclusion names" ran "$path"
done
end_scenario

# The same exclusions hold for every way of naming a directory inside the repo.
for spec in \
	"${TEST_ROOT}|${FIXTURE}/bin/lib|absolute subdirectory" \
	"${FIXTURE}|bin/lib|relative subdirectory" \
	"${TEST_ROOT}|${FIXTURE}/bin|parent of the excluded files" \
	"${TEST_ROOT}|${TEST_ROOT}/exclusions-link/bin/lib|path through a symlink to the repo"; do
	IFS='|' read -r cwd dir label <<<"$spec"
	begin_scenario

	run_runner "$cwd" "$dir"

	assert "exclusions ($label): exits 0" status_is_zero
	for path in "${excluded[@]}"; do
		assert_not "exclusions ($label): skips $path" ran "$path"
	done
	assert "exclusions ($label): runs bin/lib/test-real.sh" ran bin/lib/test-real.sh
	end_scenario
done

# Inside vendor/, the directory-relative path of vendor/bin/lib/test-helpers.sh is
# bin/lib/test-helpers.sh. Exclusions name paths from the repo root, and it still runs.
begin_scenario

run_runner "$TEST_ROOT" "${FIXTURE}/vendor"

assert "exclusions (vendor/): exits 0" status_is_zero
assert "exclusions (vendor/): runs vendor/bin/lib/test-helpers.sh" ran vendor/bin/lib/test-helpers.sh
assert "exclusions (vendor/): runs vendor/bin/lib/test-real.sh" ran vendor/bin/lib/test-real.sh
end_scenario

new_fixture scope
add_sh_test inside/test-in.sh
add_py_test inside/test_in.py
add_sh_test outside/test-out.sh 'exit 1'
add_py_test outside/test_out.py fail
add_sh_test test-root.sh 'exit 1'
add_sh_test inside-not/test-sibling-prefix.sh 'exit 1'
track_all

run_runner "$TEST_ROOT" "${FIXTURE}/inside"

assert "scope: exits 0 when every test in the directory passes" status_is_zero
assert "scope: runs inside/test-in.sh" ran inside/test-in.sh
assert "scope: runs inside/test_in.py" ran inside/test_in.py
for path in outside/test-out.sh outside/test_out.py test-root.sh inside-not/test-sibling-prefix.sh; do
	assert_not "scope: skips $path, which is outside the directory" ran "$path"
done
end_scenario

new_fixture default-dir
mkdir -p "${FIXTURE}/script"
cp -p "$RUNNER_SRC" "${FIXTURE}/script/test"
add_sh_test test-root.sh
add_sh_test sub/test-sub.sh
add_sh_test other/test-other.sh
track_all

run_in "${FIXTURE}/sub" "${FIXTURE}/script/test"

assert "default dir: exits 0 when every test passes" status_is_zero
for path in test-root.sh sub/test-sub.sh other/test-other.sh; do
	assert "default dir: runs $path from a subdirectory working directory" ran "$path"
done
end_scenario

new_fixture empty
run_runner "$TEST_ROOT" "$FIXTURE"
assert "no tests: exits non-zero for an empty repo" status_is_failure
end_scenario

new_fixture only-excluded
for path in "${excluded[@]}"; do
	add_sh_test "$path"
done
track_all
run_runner "$TEST_ROOT" "$FIXTURE"
assert "no tests: exits non-zero when every match is excluded" status_is_failure
for path in "${excluded[@]}"; do
	assert_not "no tests: skips $path" ran "$path"
done
end_scenario

new_fixture missing-dir
run_runner "$TEST_ROOT" "${FIXTURE}/does-not-exist"
assert "no tests: exits non-zero for a directory that does not exist" status_is_failure
end_scenario

new_fixture not-a-repo
rm -rf "${FIXTURE}/.git"
add_sh_test test-outside-git.sh
run_runner "$TEST_ROOT" "$FIXTURE"
assert "no tests: exits non-zero for a directory outside any git repository" status_is_failure
end_scenario

print_results
