#!/usr/bin/env bash
# shellcheck disable=SC2016 # The single-quoted scripts expand in zsh, not here.
# Tests for zsh/nvm.zsh against a fake ~/.nvm. A fake _nvm_load stands in for
# nvm. The startup fallback runs before that fake exists. On a machine with
# Homebrew's nvm, that one test loads the real nvm against the fake ~/.nvm.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NVM_ZSH="${REPO_ROOT}/zsh/nvm.zsh"

if ! command -v zsh > /dev/null 2>&1; then
	echo "zsh is not installed"
	exit 1
fi

# shellcheck source=bin/lib/test-helpers.sh
source "${REPO_ROOT}/bin/lib/test-helpers.sh"

TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_HOME="$TEST_ROOT/home"
NODES="$FAKE_HOME/.nvm/versions/node"
for v in v18.20.5 v18.20.8 v2.0.0 v22.22.0 v24.9.0 v24.13.0 v26.13.1; do
	mkdir -p "$NODES/$v/bin"
	printf '#!/bin/sh\necho %s\n' "$v" > "$NODES/$v/bin/node"
	chmod +x "$NODES/$v/bin/node"
done
mkdir -p "$FAKE_HOME/.nvm/alias" "$TEST_ROOT/sys" "$TEST_ROOT/plain"
printf '#!/bin/sh\necho system\n' > "$TEST_ROOT/sys/node"
chmod +x "$TEST_ROOT/sys/node"
LOG="$TEST_ROOT/nvm.log"

project() { # name nvmrc_content
	mkdir -p "$TEST_ROOT/$1/sub"
	printf '%s' "$2" > "$TEST_ROOT/$1/.nvmrc"
}
project exact $'v26.13.1\n'
project partial '24'
project minor '18.20'
project bare-major-two '2'
project alias 'lts/*'
project missing '99'
project commented $'24 # pinned\n'
project spaced ' 24 '

default_alias() { printf '%s\n' "$1" > "$FAKE_HOME/.nvm/alias/default"; }

# Runs a zsh script after sourcing nvm.zsh with the fake home. The fake _nvm_load
# records each call and defines an nvm that logs its arguments and knows no
# version. INITIAL_PATH sets PATH before nvm.zsh loads.
run() { # dir script
	: > "$LOG"
	(cd "$1" && env -i HOME="$FAKE_HOME" LOG="$LOG" PATH="${INITIAL_PATH:-$TEST_ROOT/sys:/usr/bin:/bin}" \
		zsh -f -c "
source '$NVM_ZSH'
_nvm_load() {
  print -r -- \"load \$*\" >> \$LOG
  nvm() { print -r -- \"nvm \$*\" >> \$LOG; [[ \$1 == version ]] && print N/A; return 0 }
  nvm_find_nvmrc() { [[ -f .nvmrc ]] && print -r -- \"\$PWD/.nvmrc\" }
}
$2" 2>&1)
}

default_alias 22.22.0

check_eq "startup puts the default node on PATH" \
	"$(run "$TEST_ROOT/plain" 'node; print $NVM_BIN')" \
	$'v22.22.0\n'"$NODES/v22.22.0/bin"

check_eq "startup does not load nvm" \
	"$(run "$TEST_ROOT/plain" 'print -r -- ${functions[nvm]}' | grep -c '_nvm_load --no-use')" "1"

check_eq "startup keeps an nvm node that node already runs" \
	"$(INITIAL_PATH="$NODES/v24.9.0/bin:/usr/bin:/bin" run "$TEST_ROOT/plain" 'node')" "v24.9.0"

check_eq "startup puts the default node ahead of a node that shadows the nvm node" \
	"$(INITIAL_PATH="$TEST_ROOT/sys:/usr/bin:$NODES/v24.9.0/bin:/bin" run "$TEST_ROOT/plain" 'node; print $#path')" \
	$'v22.22.0\n5'

check_eq "an nvm node after a system bin directory goes to the front, as nvm use does" \
	"$(INITIAL_PATH="/usr/bin:$NODES/v24.9.0/bin:/bin" run "$TEST_ROOT/exact" 'load-nvmrc >/dev/null; print $path[1]')" "$NODES/v26.13.1/bin"

check_eq "an nvm node with no system bin directory before it is replaced in place" \
	"$(INITIAL_PATH="$TEST_ROOT/sys:$NODES/v24.9.0/bin:/usr/bin:/bin" run "$TEST_ROOT/plain" 'print -l $path')" \
	"$TEST_ROOT/sys"$'\n'"$NODES/v22.22.0/bin"$'\n/usr/bin\n/bin'

check_eq "load-nvmrc uses an exact .nvmrc version from a subdirectory" \
	"$(run "$TEST_ROOT/exact/sub" 'load-nvmrc; node')" $'Now using node v26.13.1\nv26.13.1'

check_eq "a major version picks the highest installed match by number" \
	"$(run "$TEST_ROOT/partial" 'load-nvmrc >/dev/null; node')" "v24.13.0"

check_eq "a minor version picks the highest installed patch" \
	"$(run "$TEST_ROOT/minor" 'load-nvmrc >/dev/null; node')" "v18.20.8"

check_eq "major version 2 does not match v22" \
	"$(run "$TEST_ROOT/bare-major-two" 'load-nvmrc >/dev/null; node')" "v2.0.0"

check_eq "load-nvmrc is quiet when node already runs the .nvmrc version" \
	"$(run "$TEST_ROOT/exact" 'load-nvmrc >/dev/null; load-nvmrc; node')" "v26.13.1"

check_eq "cd switches node and back to the default" \
	"$(run "$TEST_ROOT/plain" "autoload -U add-zsh-hook; add-zsh-hook chpwd load-nvmrc; cd '$TEST_ROOT/exact'; node; cd '$TEST_ROOT/plain'; node")" \
	$'Now using node v26.13.1\nv26.13.1\nReverting to nvm default version\nNow using node v22.22.0\nv22.22.0'

check_eq "repeated switches do not grow PATH" \
	"$(run "$TEST_ROOT/plain" "n=\$#path; cd '$TEST_ROOT/exact'; load-nvmrc; cd '$TEST_ROOT/plain'; load-nvmrc; cd '$TEST_ROOT/exact'; load-nvmrc; (( \$#path == n )) && print same" | tail -1)" "same"

for name in alias commented spaced missing; do
	check_eq "a .nvmrc that is not an installed bare version ($name) goes to nvm" \
		"$(run "$TEST_ROOT/$name" 'load-nvmrc; cat $LOG')" \
		$'load --no-use\nnvm version\nnvm version '"$(cat "$TEST_ROOT/$name/.nvmrc")"$'\nnvm install'
done

check_eq "a Flox environment skips load-nvmrc" \
	"$(run "$TEST_ROOT/exact" 'FLOX_ENV=x load-nvmrc; node; cat $LOG')" "v22.22.0"

check_eq "the nvm command loads nvm without changing node, then runs" \
	"$(run "$TEST_ROOT/plain" 'nvm ls; cat $LOG')" $'load --no-use\nnvm ls'

default_alias 'lts/*'
check_eq "a default alias that is not a bare version loads nvm at startup" \
	"$(run "$TEST_ROOT/plain" 'print -r -- ${functions[nvm]}' | grep -c '_nvm_load --no-use')" "0"

check_eq "outside a project, a default alias nvm must resolve goes to nvm" \
	"$(INITIAL_PATH="$NODES/v24.9.0/bin:/usr/bin:/bin" run "$TEST_ROOT/plain" 'load-nvmrc; cat $LOG')" \
	$'load --no-use\nnvm version\nnvm version default'

rm "$FAKE_HOME/.nvm/alias/default"
check_eq "without a default alias, startup leaves PATH alone and load-nvmrc does nothing" \
	"$(run "$TEST_ROOT/plain" 'load-nvmrc; node; cat $LOG')" "system"

print_results
