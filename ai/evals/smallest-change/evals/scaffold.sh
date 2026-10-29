#!/usr/bin/env bash
# Builds one case's workspace in the current directory: the case's repo/ as a fresh git commit, plus a hidden .eval/ folder that the grader plugin's Stop hook runs when the session ends.
# Usage: scaffold.sh <case dir>
set -euo pipefail

case_dir="$1"
shared_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp -R "${case_dir}/repo/." .
mkdir -p .eval
cp -R "${case_dir}/hidden" .eval/hidden
cp "${shared_dir}/grade.py" .eval/
if [[ -f "${case_dir}/grade.json" ]]; then cp "${case_dir}/grade.json" .eval/; fi

# The eval run gets a fresh HOME. A fresh HOME breaks version-manager shims such as pyenv's. The agent's python3 then resolves to the first one on PATH outside HOME, and grade.sh grades with that same interpreter.
python="$(type -ap python3 | grep -v "^${HOME}/" | head -n 1 || true)"
python="${python:-$(command -v python3)}"
# shellcheck disable=SC2016 # grade.sh expands $CLAUDE_PROJECT_DIR when the hook runs it.
printf '#!/usr/bin/env bash\nexec "%s" -I "$CLAUDE_PROJECT_DIR/.eval/grade.py" "$CLAUDE_PROJECT_DIR"\n' "$python" >.eval/grade.sh

# Tool output such as uv.lock or a virtualenv would otherwise count toward the size graders.
printf '%s\n' .eval/ __pycache__/ .venv/ .pytest_cache/ build/ '*.egg-info/' uv.lock >.gitignore

git init -q
git add -A
# The scaffold runs with the operator's git config. The commit turns off that config's signing and hooks.
git -c user.name=eval -c user.email=eval@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm "Initial commit"
# grade.py diffs against this commit, so a commit by the agent still counts.
git rev-parse HEAD >.eval/base
