#!/usr/bin/env bash
# shellcheck disable=SC2016 # The single-quoted scripts expand in zsh, not here.
# Tests for zsh/pyenv-rbenv.zsh against a fake HOME. Fake pyenv and rbenv
# executables log each call's arguments to $LOG.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PYENV_RBENV_ZSH="${REPO_ROOT}/zsh/pyenv-rbenv.zsh"
ZSHRC="${REPO_ROOT}/zsh/zshrc.symlink"

if ! command -v zsh > /dev/null 2>&1; then
	echo "zsh is not installed"
	exit 1
fi

# shellcheck source=bin/lib/test-helpers.sh
source "${REPO_ROOT}/bin/lib/test-helpers.sh"

TEST_ROOT=$(mktemp -d) || exit 1
trap 'rm -rf "$TEST_ROOT"' EXIT

FAKE_HOME="$TEST_ROOT/home"
PYBIN="$TEST_ROOT/pyenv-bin"
RBBIN="$TEST_ROOT/rbenv-bin"
SYS="$TEST_ROOT/sys"
LOG="$TEST_ROOT/calls.log"
mkdir -p "$PYBIN" "$RBBIN" "$SYS" \
	"$FAKE_HOME/.pyenv/bin" "$FAKE_HOME/.pyenv/shims" "$FAKE_HOME/.pyenv/plugins/pyenv-virtualenv/shims" \
	"$FAKE_HOME/.rbenv/bin" "$FAKE_HOME/.rbenv/shims"

cat > "$PYBIN/pyenv" << 'FAKE'
#!/bin/sh
printf 'pyenv %s\n' "$*" >> "$LOG"
case "$1" in
sh-activate)
	[ -n "${FAKE_NO_VENV-}" ] && exit 1
	echo 'export VIRTUAL_ENV=/fake/venv'
	;;
sh-deactivate) echo 'unset VIRTUAL_ENV' ;;
esac
FAKE

cat > "$RBBIN/rbenv" << 'FAKE'
#!/bin/sh
printf 'rbenv %s\n' "$*" >> "$LOG"
case "$1" in
sh-rehash) echo 'print -r -- rehashed' ;;
sh-shell) echo "export RBENV_VERSION=$2" ;;
*)
	printf '[%s]' "$@"
	echo
	;;
esac
FAKE

# Copies in ~/.pyenv/bin and ~/.rbenv/bin match a git-clone install. They let
# the absent-tool tests catch code that checks the directory, not PATH.
cp "$PYBIN/pyenv" "$FAKE_HOME/.pyenv/bin/pyenv"
cp "$RBBIN/rbenv" "$FAKE_HOME/.rbenv/bin/rbenv"

for tool in python pip ruby gem; do
	printf '#!/bin/sh\necho system\n' > "$SYS/$tool"
done
for tool in python pip; do
	printf '#!/bin/sh\necho shim\n' > "$FAKE_HOME/.pyenv/shims/$tool"
done
for tool in ruby gem; do
	printf '#!/bin/sh\necho shim\n' > "$FAKE_HOME/.rbenv/shims/$tool"
done
chmod +x "$PYBIN/pyenv" "$RBBIN/rbenv" "$FAKE_HOME"/.pyenv/bin/* "$FAKE_HOME"/.rbenv/bin/* \
	"$SYS"/* "$FAKE_HOME"/.pyenv/shims/* "$FAKE_HOME"/.rbenv/shims/*

NO_PLUGIN_HOME="$TEST_ROOT/no-plugin-home"
cp -R "$FAKE_HOME" "$NO_PLUGIN_HOME"
rm -rf "$NO_PLUGIN_HOME/.pyenv/plugins"

DEFAULT_PATH="$PYBIN:$RBBIN:$SYS:/usr/bin:/bin"
PY_SHIMS="$FAKE_HOME/.pyenv/shims"
RB_SHIMS="$FAKE_HOME/.rbenv/shims"

# Runs a zsh script after sourcing pyenv-rbenv.zsh with the fake home.
# INITIAL_PATH sets PATH before the file loads. RUN_HOME replaces the fake home.
run() { # script
	: > "$LOG"
	env -i HOME="${RUN_HOME:-$FAKE_HOME}" LOG="$LOG" PATH="${INITIAL_PATH:-$DEFAULT_PATH}" \
		zsh -f -c "source '$PYENV_RBENV_ZSH'
$1" 2>&1
}

check_eq "startup runs neither pyenv nor rbenv" \
	"$(run 'cat $LOG')" ""

check_eq "startup puts the rbenv and pyenv directories at the front of PATH in the order the init commands produced" \
	"$(run 'print -l $path')" \
	"$RB_SHIMS
$FAKE_HOME/.rbenv/bin
$FAKE_HOME/.pyenv/plugins/pyenv-virtualenv/shims
$PY_SHIMS
$FAKE_HOME/.pyenv/bin
$PYBIN
$RBBIN
$SYS
/usr/bin
/bin"

check_eq "python, pip, ruby, and gem resolve to the shims, ahead of system copies" \
	"$(run 'whence -v python pip ruby gem')" \
	"python is $PY_SHIMS/python
pip is $PY_SHIMS/pip
ruby is $RB_SHIMS/ruby
gem is $RB_SHIMS/gem"

nested_path=$(run 'print -r -- $PATH')
for shape in \
	"front:$PY_SHIMS:$DEFAULT_PATH" \
	"middle:$PYBIN:$RBBIN:$PY_SHIMS:$SYS:/usr/bin:/bin" \
	"end:$DEFAULT_PATH:$PY_SHIMS" \
	"twice:$PY_SHIMS:$PYBIN:$RBBIN:$PY_SHIMS:$SYS:/usr/bin:/bin" \
	"nested shell:$nested_path"; do
	check_eq "an inherited pyenv shims entry (${shape%%:*}) appears once, fourth in PATH" \
		"$(INITIAL_PATH="${shape#*:}" run 'print ${#${(M)path:#$HOME/.pyenv/shims}} ${path[(i)$HOME/.pyenv/shims]}')" "1 4"
done

check_eq "PYENV_VIRTUALENV_INIT=1 is exported" \
	"$(run 'printenv PYENV_VIRTUALENV_INIT')" "1"

check_eq "sourcing the file twice leaves _pyenv_virtualenv_hook in precmd_functions once" \
	"$(run "source '$PYENV_RBENV_ZSH'"'; print ${#${(M)precmd_functions:#_pyenv_virtualenv_hook}}')" "1"

check_eq "_pyenv_virtualenv_hook evals pyenv sh-activate in the current shell" \
	"$(run '_pyenv_virtualenv_hook; print -r -- $VIRTUAL_ENV')" "/fake/venv"

check_eq "_pyenv_virtualenv_hook deactivates an active virtualenv when sh-activate fails" \
	"$(run 'VIRTUAL_ENV=/old; export FAKE_NO_VENV=1; _pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset}')" "unset"

check_eq "_pyenv_virtualenv_hook keeps the previous exit status" \
	"$(run 'false; _pyenv_virtualenv_hook; print $?')" "1"

check_eq "without the pyenv-virtualenv plugin, the file adds no virtualenv shims, variable, or hook" \
	"$(RUN_HOME="$NO_PLUGIN_HOME" run 'print ${#${(M)path:#*/pyenv-virtualenv/*}} ${PYENV_VIRTUALENV_INIT-unset} ${+functions[_pyenv_virtualenv_hook]} ${#precmd_functions} ${path[(i)$HOME/.pyenv/shims]}')" \
	"0 unset 0 0 3"

check_eq "RBENV_SHELL=zsh is exported" \
	"$(run 'printenv RBENV_SHELL')" "zsh"

check_eq "the rbenv function evals sh-rehash and sh-shell and passes other subcommands to rbenv" \
	"$(run 'rbenv rehash; rbenv shell 3.3.0; print -r -- $RBENV_VERSION; rbenv version "a b"')" \
	$'rehashed\n3.3.0\n[version][a b]'

check_eq "pyenv stays a plain command" \
	"$(run 'whence -w pyenv')" "pyenv: command"

check_eq "without pyenv on PATH, the file adds no pyenv PATH entries, variables, or hook" \
	"$(INITIAL_PATH="$RBBIN:$SYS:/usr/bin:/bin" run 'print ${#${(M)path:#*/.pyenv/*}} ${PYENV_VIRTUALENV_INIT-unset} ${+functions[_pyenv_virtualenv_hook]} ${#precmd_functions}')" \
	"0 unset 0 0"

check_eq "without rbenv on PATH, the file adds no rbenv PATH entries, variables, or function" \
	"$(INITIAL_PATH="$PYBIN:$SYS:/usr/bin:/bin" run 'print ${#${(M)path:#*/.rbenv/*}} ${RBENV_SHELL-unset} ${RBENV_ROOT-unset} ${+functions[rbenv]}')" \
	"0 unset unset 0"

check_eq "zshrc sources pyenv-rbenv.zsh and no longer evals pyenv or rbenv init" \
	"$(grep -c 'zsh/pyenv-rbenv.zsh' "$ZSHRC") $(grep -cE '^[^#]*eval "\$\((pyenv|rbenv) ' "$ZSHRC")" "1 0"

print_results
