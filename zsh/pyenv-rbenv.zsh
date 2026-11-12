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
    _pyenv_virtualenv_hook() {
      local ret=$?
      if [ -n "${VIRTUAL_ENV-}" ]; then
        eval "$(pyenv sh-activate --quiet || pyenv sh-deactivate --quiet || true)" || true
      else
        eval "$(pyenv sh-activate --quiet || true)" || true
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
