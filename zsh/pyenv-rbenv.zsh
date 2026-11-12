# `pyenv init --path`, `pyenv virtualenv-init -`, and `rbenv init - zsh` take
# about 600 ms together. This file sets up the shell the way their output does,
# without running pyenv or rbenv.
# It leaves out their rehash. `pyenv install` and `rbenv install` rehash when
# they finish. The pip-rehash and gem-rehash exec hooks rehash after
# `pip install` and `gem install`. An executable added any other way needs
# `pyenv rehash` or `rbenv rehash` before its shim exists.

if command -v pyenv >/dev/null 2>&1; then
  export PATH="$HOME/.pyenv/bin:$PATH"

  # pyenv init --path
  path=("$HOME/.pyenv/shims" ${path:#$HOME/.pyenv/shims})

  # pyenv virtualenv-init -
  if [[ -d $HOME/.pyenv/plugins/pyenv-virtualenv ]]; then
    export PATH="$HOME/.pyenv/plugins/pyenv-virtualenv/shims:$PATH"
    export PYENV_VIRTUALENV_INIT=1

    # Sets REPLY to everything `pyenv sh-activate` reads: the version
    # variables, the version file that applies and its contents, and the
    # names in the versions directory. Creating or deleting a virtualenv adds
    # or removes a name there. It reads contents and names, not modification
    # times, because two writes in the same second share a modification time.
    # The version file search follows pyenv-version-file: upward from
    # PYENV_DIR, then upward from PWD, then $PYENV_ROOT/version. pyenv reads
    # the current directory only to find the version file, so a cd that keeps
    # the same version file leaves REPLY unchanged.
    _pyenv_virtualenv_inputs() {
      local root=${PYENV_ROOT:-$HOME/.pyenv} start dir file contents
      for start in ${PYENV_DIR:+${PYENV_DIR:a}} $PWD; do
        dir=$start
        while [[ ! -f $dir/.python-version && $dir != / ]]; do
          dir=${dir:h}
        done
        if [[ -f $dir/.python-version ]]; then
          file=$dir/.python-version
          break
        fi
      done
      : ${file:=$root/version}
      [[ -r $file ]] && IFS= read -r -d '' contents < $file
      local -a versions=($root/versions/*(N:t))
      REPLY="${PYENV_VERSION-}"$'\0'"${VIRTUAL_ENV-}"$'\0'"$file"$'\0'"$contents"$'\0'"${(j:/:)versions}"
    }

    # Runs pyenv only when an input changed since its last run. The inputs are
    # recorded after the eval, because activation changes VIRTUAL_ENV and
    # PYENV_VERSION.
    typeset -g _pyenv_virtualenv_last_inputs
    _pyenv_virtualenv_hook() {
      local ret=$? REPLY
      _pyenv_virtualenv_inputs
      if [[ $REPLY != "$_pyenv_virtualenv_last_inputs" ]]; then
        if [ -n "${VIRTUAL_ENV-}" ]; then
          eval "$(pyenv sh-activate --quiet || pyenv sh-deactivate --quiet || true)" || true
        else
          eval "$(pyenv sh-activate --quiet || true)" || true
        fi
        _pyenv_virtualenv_inputs
        _pyenv_virtualenv_last_inputs=$REPLY
      fi
      return $ret
    }
    typeset -g -a precmd_functions
    if [[ -z $precmd_functions[(r)_pyenv_virtualenv_hook] ]]; then
      precmd_functions=(_pyenv_virtualenv_hook $precmd_functions)
    fi
  fi
fi

if command -v rbenv >/dev/null 2>&1; then
  export RBENV_ROOT="$HOME/.rbenv"
  export PATH="$RBENV_ROOT/bin:$PATH"

  # rbenv init - zsh
  export PATH="$RBENV_ROOT/shims:$PATH"
  export RBENV_SHELL=zsh
  rbenv() {
    local command
    command="${1:-}"
    if [ "$#" -gt 0 ]; then
      shift
    fi

    case "$command" in
    rehash|shell)
      eval "$(rbenv "sh-$command" "$@")";;
    *)
      command rbenv "$command" "$@";;
    esac
  }
fi
