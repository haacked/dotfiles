#!/usr/bin/env bash
# Builds one case's workspace in the current directory: the case's repo/ as a fresh git commit, plus a hidden .eval/ folder and a Stop hook that grades the agent's work when the session ends.
# Usage: scaffold.sh <case dir>
set -euo pipefail

case_dir="$1"
shared_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cp -R "${case_dir}/repo/." .
mkdir -p .eval .claude
cp -R "${case_dir}/hidden" .eval/hidden
cp "${case_dir}/grade.json" "${shared_dir}/grade.py" .eval/

# The eval run gets a fresh HOME. A fresh HOME breaks version-manager shims such as pyenv's. The agent's python3 then resolves to the first one on PATH outside HOME, and the hook grades with that same interpreter.
python="$(type -ap python3 | grep -v "^${HOME}/" | head -n 1 || true)"
python="${python:-$(command -v python3)}"

# The Stop hook lives in the workspace's own settings rather than in the plugin. Both eval arms therefore grade the same way.
cat >.claude/settings.json <<EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "${python} -I \"\$CLAUDE_PROJECT_DIR/.eval/grade.py\" \"\$CLAUDE_PROJECT_DIR\""
          }
        ]
      }
    ]
  }
}
EOF

# Tool output such as uv.lock or a virtualenv would otherwise count toward the diff-size grader.
printf '%s\n' .eval/ .claude/ __pycache__/ .venv/ .pytest_cache/ build/ '*.egg-info/' uv.lock >.gitignore

git init -q
git add -A
# The scaffold runs with the operator's git config. The commit turns off that config's signing and hooks.
git -c user.name=eval -c user.email=eval@example.com -c commit.gpgsign=false -c core.hooksPath=/dev/null commit -qm "Initial commit"
# grade.py diffs against this commit, so a commit by the agent still counts.
git rev-parse HEAD >.eval/base
