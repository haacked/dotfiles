#!/usr/bin/env bash
# PostToolUse hook for Edit and Write. Lints an edited Markdown file with
# markdownlint and formats an edited Python file with the project's own ruff. A
# tool runs only in a project that configures it, and only on a file inside that
# project.
#
# PostToolUse shows a hook's stderr to Claude only when the hook exits 2.
set -uo pipefail

input=$(cat)
file=$(jq -r '.tool_input.file_path // empty' <<<"$input" 2>/dev/null)
project="${CLAUDE_PROJECT_DIR:-$(jq -r '.cwd // empty' <<<"$input" 2>/dev/null)}"
[[ -f "$file" && -d "$project" ]] || exit 0

has_file() { # name...
	local name
	for name in "$@"; do
		[[ -e "$project/$name" ]] && return 0
	done
	return 1
}

# Resolves both paths before the prefix comparison, because symlinks, `..`, and a
# trailing slash would defeat it.
inside_project() {
	project=$(cd "$project" && pwd -P) || return 1
	file="$(cd "$(dirname "$file")" && pwd -P)/$(basename "$file")"
	[[ "$file" == "$project"/* ]]
}

# Prints the line ranges this edit wrote as "first-last" pairs joined by commas.
# Without a patch, as when Write creates a file, the range covers the whole file.
changed_ranges() {
	jq -r '(.tool_response.structuredPatch // []) as $patch
		| if ($patch | length) > 0
		then [$patch[] | "\(.newStart)-\(.newStart + .newLines - 1)"] | join(",")
		else "1-999999999" end' <<<"$input"
}

case "$file" in
*.md | *.markdown)
	command -v markdownlint >/dev/null 2>&1 || exit 0
	# A markdownlint-cli2 project keeps its ignore list where markdownlint-cli never reads it.
	has_file .markdownlint-cli2.jsonc .markdownlint-cli2.yaml .markdownlint-cli2.cjs .markdownlint-cli2.mjs && exit 0
	has_file .markdownlint.json .markdownlint.jsonc .markdownlint.yaml .markdownlint.yml .markdownlintrc || exit 0
	inside_project || exit 0
	# markdownlint-cli reads its config from the working directory.
	report=$(cd "$project" && markdownlint "$file" 2>&1) && exit 0
	# Only violations on lines this edit wrote go back to Claude. The file may
	# already break rules elsewhere.
	awk -v prefix="$file:" -v ranges="$(changed_ranges)" '
		BEGIN { count = split(ranges, range, ",") }
		index($0, prefix) == 1 {
			line = substr($0, length(prefix) + 1) + 0
			for (i = 1; i <= count; i++) {
				split(range[i], bound, "-")
				if (line >= bound[1] + 0 && line <= bound[2] + 0) { print; found = 1; next }
			}
		}
		END { exit !found }' <<<"$report" >&2 && exit 2
	;;
*.py)
	# A ruff from PATH can differ from the version the project pins. Two ruff
	# versions format the same file differently.
	ruff="$project/.venv/bin/ruff"
	[[ -x "$ruff" ]] || exit 0
	has_file ruff.toml .ruff.toml || grep -q '^\[tool\.ruff' "$project/pyproject.toml" 2>/dev/null || exit 0
	inside_project || exit 0
	"$ruff" format --quiet "$file" >&2 || exit 2
	;;
esac
exit 0
