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

# The fake sh-activate picks the version the way pyenv does: PYENV_VERSION, then
# the nearest .python-version above the current folder, then
# $PYENV_ROOT/version. A version named venv-* activates /fake/venv-*. Any other
# version means no virtualenv. No version at all activates /fake/venv.
cat > "$PYBIN/pyenv" << 'FAKE'
#!/bin/sh
printf 'pyenv %s\n' "$*" >> "$LOG"
version() {
	if [ -n "${PYENV_VERSION-}" ]; then
		echo "$PYENV_VERSION"
		return
	fi
	dir=$(pwd)
	while :; do
		if [ -f "$dir/.python-version" ]; then
			cat "$dir/.python-version"
			return
		fi
		[ "$dir" = / ] && break
		dir=$(dirname "$dir")
	done
	root=${PYENV_ROOT:-$HOME/.pyenv}
	[ -f "$root/version" ] && cat "$root/version"
}
case "$1" in
sh-activate)
	[ -n "${FAKE_NO_VENV-}" ] && exit 1
	v=$(version)
	case "$v" in
	'') echo 'export VIRTUAL_ENV=/fake/venv' ;;
	venv-*) echo "export VIRTUAL_ENV=/fake/$v" ;;
	*) exit 1 ;;
	esac
	;;
sh-deactivate) echo 'unset VIRTUAL_ENV' ;;
local) printf '%s\n' "$2" > .python-version ;;
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

GLOBAL_HOME="$TEST_ROOT/global-home"
cp -R "$FAKE_HOME" "$GLOBAL_HOME"

# Runs a zsh script after sourcing pyenv-rbenv.zsh with the fake home.
# INITIAL_PATH sets PATH before the file loads. RUN_HOME replaces the fake home.
# RUN_DIR sets the starting folder, which defaults to $TEST_ROOT so that no
# .python-version outside the test reaches the fake pyenv.
run() ( # script
	: > "$LOG"
	cd "${RUN_DIR:-$TEST_ROOT}" || exit 1
	env -i HOME="${RUN_HOME:-$FAKE_HOME}" LOG="$LOG" PATH="${INITIAL_PATH:-$DEFAULT_PATH}" \
		zsh -f -c "source '$PYENV_RBENV_ZSH'
$1" 2>&1
)

# Runs a zsh script in a new empty folder under $TEST_ROOT. The script can call
# activations, which prints how many times pyenv sh-activate has run, and
# pyenv_calls, which prints how many times pyenv has run.
run_hook() { # script
	RUN_DIR=$(mktemp -d "$TEST_ROOT/case.XXXXXX") run 'activations() { grep -c "^pyenv sh-activate" $LOG }
pyenv_calls() { grep -c "^pyenv " $LOG }
'"$1"
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

# A hook that records its inputs before its own eval sees its activation as an
# outside change and runs pyenv both times.
for shape in \
	"no version file:" \
	"a .python-version naming a virtualenv:print venv-a > .python-version" \
	"a .python-version naming no virtualenv:print system > .python-version" \
	"PYENV_VERSION exported:export PYENV_VERSION=venv-c" \
	"no virtualenv to activate:export FAKE_NO_VENV=1"; do
	check_eq "with ${shape%%:*}, calling _pyenv_virtualenv_hook twice with nothing changed runs pyenv once" \
		"$(run_hook "${shape#*:}"'
_pyenv_virtualenv_hook; _pyenv_virtualenv_hook; pyenv_calls')" "1"
done

check_eq "with only the global version file, calling _pyenv_virtualenv_hook twice with nothing changed runs pyenv once" \
	"$(RUN_HOME="$GLOBAL_HOME" run_hook 'print venv-g > $HOME/.pyenv/version
_pyenv_virtualenv_hook; _pyenv_virtualenv_hook; pyenv_calls')" "1"

check_eq "after _pyenv_virtualenv_hook deactivates a virtualenv, the next call with nothing changed runs sh-activate no more" \
	"$(run_hook 'VIRTUAL_ENV=/old; export FAKE_NO_VENV=1
_pyenv_virtualenv_hook; _pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset} $(activations)')" "unset 1"

check_eq "_pyenv_virtualenv_hook keeps the previous exit status, failing or zero, when it skips pyenv" \
	"$(run_hook '_pyenv_virtualenv_hook; (exit 42); _pyenv_virtualenv_hook; r1=$?; true; _pyenv_virtualenv_hook; print $r1 $? $(activations)')" "42 0 1"

check_eq "_pyenv_virtualenv_hook skips pyenv after a cd that keeps the same version file" \
	"$(run_hook 'print venv-a > .python-version; mkdir sub; _pyenv_virtualenv_hook; cd sub; _pyenv_virtualenv_hook; activations')" "1"

check_eq "entering a folder whose .python-version names a virtualenv activates it" \
	"$(run_hook 'print system > .python-version; mkdir proj; print venv-a > proj/.python-version
_pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset}
cd proj; _pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset}')" $'unset\n/fake/venv-a'

check_eq "leaving a folder whose .python-version names a virtualenv deactivates it" \
	"$(run_hook 'print system > .python-version; mkdir proj; print venv-a > proj/.python-version; cd proj
_pyenv_virtualenv_hook; cd ..; _pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset}')" "unset"

check_eq "moving between two folders that name different virtualenvs activates each in turn" \
	"$(run_hook 'mkdir a b; print venv-a > a/.python-version; print venv-b > b/.python-version
cd a; _pyenv_virtualenv_hook; cd ../b; _pyenv_virtualenv_hook; print -r -- $VIRTUAL_ENV
cd ../a; _pyenv_virtualenv_hook; print -r -- $VIRTUAL_ENV')" $'/fake/venv-b\n/fake/venv-a'

# Each case sets up a folder, calls the hook, changes one input, and calls the
# hook again. The rewrites keep the same length and land in the same second, so
# only the contents tell the old file from the new one.
while IFS='|' read -r name setup change expected; do
	check_eq "$name at the next call" \
		"$(run_hook "$setup"'
_pyenv_virtualenv_hook
'"$change"'
_pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset}')" "$expected"
done << 'CASES'
pyenv local in the current folder activates the new virtualenv|print venv-a > .python-version|pyenv local venv-b|/fake/venv-b
pyenv local in a folder that inherited its version from a parent activates the new virtualenv|print system > .python-version; mkdir proj; cd proj|pyenv local venv-a|/fake/venv-a
rewriting the parent .python-version from a subfolder activates the new virtualenv|mkdir -p proj/sub; print venv-a > proj/.python-version; cd proj/sub|print venv-b > ../.python-version|/fake/venv-b
deleting the .python-version that named the active virtualenv deactivates it|print system > .python-version; mkdir proj; print venv-a > proj/.python-version; cd proj|rm .python-version|unset
rewriting $PYENV_ROOT/version activates the new virtualenv|export PYENV_ROOT=$PWD/root; mkdir root; print venv-g > root/version|print venv-h > root/version|/fake/venv-h
exporting PYENV_VERSION activates its virtualenv|:|export PYENV_VERSION=venv-c|/fake/venv-c
changing PYENV_VERSION activates the new virtualenv|export PYENV_VERSION=venv-c|PYENV_VERSION=venv-d|/fake/venv-d
unsetting PYENV_VERSION falls back to the .python-version virtualenv|print venv-a > .python-version; export PYENV_VERSION=venv-c|unset PYENV_VERSION|/fake/venv-a
CASES

check_eq "rewriting ~/.pyenv/version activates the new virtualenv at the next call" \
	"$(RUN_HOME="$GLOBAL_HOME" run_hook 'print venv-g > $HOME/.pyenv/version; _pyenv_virtualenv_hook
print venv-h > $HOME/.pyenv/version; _pyenv_virtualenv_hook; print -r -- $VIRTUAL_ENV')" "/fake/venv-h"

check_eq "unsetting VIRTUAL_ENV by hand makes the next call run sh-activate again" \
	"$(run_hook '_pyenv_virtualenv_hook; unset VIRTUAL_ENV; _pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset} $(activations)')" "/fake/venv 2"

check_eq "setting VIRTUAL_ENV by hand makes the next call run sh-activate again" \
	"$(run_hook '_pyenv_virtualenv_hook; VIRTUAL_ENV=/manual; _pyenv_virtualenv_hook; print -r -- $VIRTUAL_ENV $(activations)')" "/fake/venv 2"

check_eq "setting VIRTUAL_ENV by hand where no virtualenv applies makes the next call deactivate it" \
	"$(run_hook 'export FAKE_NO_VENV=1; _pyenv_virtualenv_hook; VIRTUAL_ENV=/manual; _pyenv_virtualenv_hook; print -r -- ${VIRTUAL_ENV-unset} $(activations)')" "unset 2"

# The versions folder starts with an old modification time, so creating a
# virtualenv in the same second as the first call still changes it.
check_eq "creating a virtualenv makes the next call run sh-activate again" \
	"$(run_hook 'export PYENV_ROOT=$PWD/root; mkdir -p root/versions; touch -t 200001010000 root/versions
_pyenv_virtualenv_hook; mkdir $PYENV_ROOT/versions/venv-new; _pyenv_virtualenv_hook; activations')" "2"

check_eq "with PYENV_DIR set, _pyenv_virtualenv_hook runs sh-activate at every call" \
	"$(run_hook 'export PYENV_DIR=$PWD; _pyenv_virtualenv_hook; _pyenv_virtualenv_hook; activations')" "2"

check_eq "_pyenv_virtualenv_hook skips pyenv on a second call in the root folder" \
	"$(run_hook 'cd /; _pyenv_virtualenv_hook; _pyenv_virtualenv_hook; activations')" "1"

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
