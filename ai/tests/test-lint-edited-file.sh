#!/usr/bin/env bash
# Tests for ai/bin/lint-edited-file.sh, the PostToolUse hook that lints a Markdown
# file or formats a Python file after Claude edits it.
#
# The hook runs in every project. Its gate matters most: a tool runs only in a
# project that configures it, and only on a file inside that project.
#
# Usage: test-lint-edited-file.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
HOOK="${REPO_ROOT}/ai/bin/lint-edited-file.sh"

# shellcheck source=bin/lib/test-helpers.sh
source "${REPO_ROOT}/bin/lib/test-helpers.sh"

# The hook resolves symlinks, and macOS puts mktemp under the /var symlink.
TEST_ROOT=$(cd "$(mktemp -d)" && pwd -P) || exit 1
SHIM_BIN="${TEST_ROOT}/bin"
TOOL_LOG="${TEST_ROOT}/tool-calls"
STDERR_FILE="${TEST_ROOT}/stderr"
HOOK_STATUS=0

cleanup() {
	rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

check_eq() { # description actual expected
	if [[ "$2" == "$3" ]]; then
		passes=$((passes + 1))
	else
		echo "FAIL: $1"
		echo "  expected [$3], got [$2]"
		failures=$((failures + 1))
	fi
}

# The markdownlint shim logs its working directory and arguments. On a nonzero
# MARKDOWNLINT_SHIM_STATUS it reports one violation on MARKDOWNLINT_SHIM_LINE.
mkdir -p "$SHIM_BIN"
cat >"${SHIM_BIN}/markdownlint" <<SHIM
#!/usr/bin/env bash
printf 'markdownlint %s %s\n' "\$PWD" "\$*" >>"${TOOL_LOG}"
[[ "\${MARKDOWNLINT_SHIM_STATUS:-0}" -eq 0 ]] && exit 0
echo "\$1:\${MARKDOWNLINT_SHIM_LINE:-1} MD012/no-multiple-blanks Multiple consecutive blank lines" >&2
exit "\$MARKDOWNLINT_SHIM_STATUS"
SHIM
# A ruff on PATH must never run. Its shim logs under a distinct name.
cat >"${SHIM_BIN}/ruff" <<SHIM
#!/usr/bin/env bash
printf 'path-ruff %s\n' "\$*" >>"${TOOL_LOG}"
SHIM
chmod +x "${SHIM_BIN}/markdownlint" "${SHIM_BIN}/ruff"

new_project() { # name
	local dir="${TEST_ROOT}/$1"
	mkdir -p "$dir"
	printf '%s\n' "$dir"
}

add_venv_ruff() { # project
	mkdir -p "$1/.venv/bin"
	cat >"$1/.venv/bin/ruff" <<SHIM
#!/usr/bin/env bash
printf 'ruff %s\n' "\$*" >>"${TOOL_LOG}"
echo "ruff found a problem" >&2
exit "\${RUFF_SHIM_STATUS:-0}"
SHIM
	chmod +x "$1/.venv/bin/ruff"
}

# Runs the hook on the JSON from stdin. An empty project leaves CLAUDE_PROJECT_DIR
# empty, which the hook treats as unset.
run_hook_json() { # project
	: >"$TOOL_LOG"
	CLAUDE_PROJECT_DIR="$1" PATH="${SHIM_BIN}:${PATH}" "$HOOK" >/dev/null 2>"$STDERR_FILE"
	HOOK_STATUS=$?
}

# Runs the hook on an Edit of the file. With no range the input carries no patch,
# as when Write creates a file.
run_hook() { # project file [new_start new_lines]
	local patch='[]'
	mkdir -p "$(dirname "$2")"
	touch "$2"
	if [[ $# -ge 4 ]]; then
		patch=$(jq -cn --argjson start "$3" --argjson lines "$4" '[{newStart: $start, newLines: $lines}]')
	fi
	run_hook_json "$1" <<<"$(jq -cn --arg path "$2" --argjson patch "$patch" \
		'{tool_name: "Edit", tool_input: {file_path: $path}, tool_response: {structuredPatch: $patch}}')"
}

project=$(new_project md-configured)
printf '{}\n' >"$project/.markdownlint.json"
run_hook "$project" "$project/README.md"
check_eq "Markdown in a configured project passes" "$HOOK_STATUS" "0"
check_eq "markdownlint runs on the file from the project directory" \
	"$(cat "$TOOL_LOG")" "markdownlint ${project} ${project}/README.md"

MARKDOWNLINT_SHIM_STATUS=1 run_hook "$project" "$project/README.md"
check_eq "A violation in a new file exits 2" "$HOOK_STATUS" "2"
assert "A violation reaches stderr" grep -Fq "MD012" "$STDERR_FILE"

MARKDOWNLINT_SHIM_STATUS=1 MARKDOWNLINT_SHIM_LINE=11 run_hook "$project" "$project/README.md" 10 3
check_eq "A violation on an edited line exits 2" "$HOOK_STATUS" "2"

MARKDOWNLINT_SHIM_STATUS=1 MARKDOWNLINT_SHIM_LINE=2 run_hook "$project" "$project/README.md" 10 3
check_eq "A violation outside the edited lines passes" "$HOOK_STATUS" "0"
check_eq "A violation outside the edited lines stays off stderr" "$(cat "$STDERR_FILE")" ""

project=$(new_project md-unconfigured)
run_hook "$project" "$project/README.md"
check_eq "Markdown in a project without a markdownlint config passes" "$HOOK_STATUS" "0"
check_eq "Markdown in a project without a markdownlint config runs nothing" "$(cat "$TOOL_LOG")" ""

project=$(new_project md-cli2)
printf '{}\n' >"$project/.markdownlint.json"
printf '{}\n' >"$project/.markdownlint-cli2.jsonc"
run_hook "$project" "$project/README.md"
check_eq "A markdownlint-cli2 project runs nothing" "$(cat "$TOOL_LOG")" ""

project=$(new_project py-pyproject)
printf '[tool.ruff]\nline-length = 120\n' >"$project/pyproject.toml"
add_venv_ruff "$project"
run_hook "$project" "$project/app.py"
check_eq "Python in a ruff project passes" "$HOOK_STATUS" "0"
check_eq "Python in a ruff project runs the project's ruff on the file" \
	"$(cat "$TOOL_LOG")" "ruff format --quiet ${project}/app.py"

RUFF_SHIM_STATUS=2 run_hook "$project" "$project/app.py"
check_eq "A ruff format failure exits 2" "$HOOK_STATUS" "2"

project=$(new_project py-ruff-toml)
printf 'line-length = 120\n' >"$project/ruff.toml"
add_venv_ruff "$project"
run_hook "$project" "$project/app.py"
check_eq "A ruff.toml also opts a project in" "$(cat "$TOOL_LOG")" "ruff format --quiet ${project}/app.py"

project=$(new_project py-no-venv)
printf '[tool.ruff]\n' >"$project/pyproject.toml"
run_hook "$project" "$project/app.py"
check_eq "A ruff project without its own ruff runs nothing" "$(cat "$TOOL_LOG")" ""

project=$(new_project py-unconfigured)
printf '[tool.black]\n' >"$project/pyproject.toml"
add_venv_ruff "$project"
run_hook "$project" "$project/app.py"
check_eq "Python in a project without ruff config passes" "$HOOK_STATUS" "0"
check_eq "Python in a project without ruff config runs nothing" "$(cat "$TOOL_LOG")" ""

project=$(new_project bounds)
printf '{}\n' >"$project/.markdownlint.json"
ln -s "$project" "${TEST_ROOT}/bounds-link"
run_hook "${TEST_ROOT}/bounds-link" "$project/doc.md"
check_eq "A project reached through a symlink still lints its files" \
	"$(cat "$TOOL_LOG")" "markdownlint ${project} ${project}/doc.md"

run_hook "${project}/" "$project/doc.md"
check_eq "A trailing slash on the project still lints its files" \
	"$(cat "$TOOL_LOG")" "markdownlint ${project} ${project}/doc.md"

run_hook "$project" "${project}/../elsewhere/notes.md"
check_eq "A path that climbs out of the project runs nothing" "$(cat "$TOOL_LOG")" ""

run_hook "$project" "${TEST_ROOT}/elsewhere/notes.md"
check_eq "A file outside the project runs nothing" "$(cat "$TOOL_LOG")" ""

run_hook "$project" "$project/script.sh"
check_eq "Another file type runs nothing" "$(cat "$TOOL_LOG")" ""

run_hook_json "" <<<"$(jq -cn --arg path "$project/doc.md" --arg cwd "$project" '{tool_input: {file_path: $path}, cwd: $cwd}')"
check_eq "Without CLAUDE_PROJECT_DIR the hook uses the input's cwd" \
	"$(cat "$TOOL_LOG")" "markdownlint ${project} ${project}/doc.md"

(cd "$project" && run_hook_json "" <<<"$(jq -cn --arg path "$project/doc.md" '{tool_input: {file_path: $path}}')")
check_eq "Without any project directory the hook runs nothing" "$(cat "$TOOL_LOG")" ""

run_hook_json "$project" <<<'{"tool_name": "Edit"}'
check_eq "Input without a file path exits 0" "$HOOK_STATUS" "0"
check_eq "Input without a file path runs nothing" "$(cat "$TOOL_LOG")" ""

print_results
