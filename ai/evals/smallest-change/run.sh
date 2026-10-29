#!/usr/bin/env bash
# Runs the smallest-change eval once with the rule (this plugin) and once without it (a baseline plugin built here), then prints the per-grader difference.
# Usage: run.sh [claude plugin eval options, such as --case csv-export --runs 1 --max-cost-usd 1]
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="${here}/results/$(date -u +%Y-%m-%dT%H-%M-%SZ)"

# The eval refuses an eval folder that links outside its plugin, so the baseline plugin holds a real copy of the cases. Its hooks are this plugin's hooks without the SessionStart hook that prints the rule.
baseline="${out}/baseline-plugin"
mkdir -p "${baseline}/.claude-plugin" "${baseline}/hooks" "${baseline}/evals"
printf '{"name": "smallest-change-baseline", "version": "0.1.0"}\n' >"${baseline}/.claude-plugin/plugin.json"
python3 -I -c 'import json, sys; hooks = json.load(open(sys.argv[1])); del hooks["hooks"]["SessionStart"]; json.dump(hooks, open(sys.argv[2], "w"), indent=2)' \
	"${here}/hooks/hooks.json" "${baseline}/hooks/hooks.json"
for entry in "${here}/evals"/*; do
	[[ "$(basename "$entry")" == results ]] || cp -R "$entry" "${baseline}/evals/"
done

# --threshold 0 makes a low score exit 0, so a nonzero exit means the run itself failed.
for arm in with without; do
	plugin="$here"
	[[ "$arm" == without ]] && plugin="$baseline"
	claude plugin eval "$plugin" --ablation none --threshold 0 --scaffold --allow-tools Edit Write Bash \
		--no-publish --output-dir "${out}/${arm}" --json "${out}/${arm}.json" "$@"
done

python3 -I "${here}/compare.py" "${out}/with.json" "${out}/without.json"
