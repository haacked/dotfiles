# Sourcing nvm.sh takes about a second. This file puts the right node on PATH
# without loading nvm. The nvm command loads the real nvm the first time it runs.

export NVM_DIR="$HOME/.nvm"

# Sets REPLY to the directory of the installed node that `nvm use` picks for a
# version such as 24, v24.1, or 26.13.1: the highest installed match. Fails for
# any other spec, such as lts/* or a commented .nvmrc, and for a version with
# no installed match, so that the caller can hand those to nvm.
_nvm_installed_dir() { # spec
  [[ $1 =~ '^v?[0-9]+(\.[0-9]+){0,2}$' ]] || return 1
  local -a dirs=("$NVM_DIR"/versions/node/v${1#v}(|.*)(N/nOn))
  (( $#dirs )) || return 1
  REPLY=$dirs[1]
}

# Changes PATH the way `nvm use` does. The node's bin directory replaces the
# first nvm node on PATH. It goes to the front instead when PATH has no nvm
# node, or when a system bin directory comes before that node.
_nvm_activate() { # node_dir
  local i=${path[(i)$NVM_DIR/versions/node/*/bin]}
  if (( i > $#path || ${path[(i)(/usr/local|/usr|)/bin]} < i )); then
    path=("$1/bin" $path)
  else
    path[i]="$1/bin"
  fi
  export NVM_BIN="$1/bin" NVM_INC="$1/include/node"
}

# Sets REPLY to the PATH directory of the node that `node` runs, or to nothing.
# ${commands[node]} would do the same, but it reads every PATH directory after
# each PATH change.
_nvm_node_dir() {
  REPLY=
  local d
  for d in $path; do
    [[ -x $d/node ]] && { REPLY=$d; return; }
  done
}

_nvm_load() { # nvm.sh args
  unfunction nvm 2>/dev/null
  # Homebrew's nvm.sh sources the real nvm.sh without arguments.
  # The real nvm.sh therefore sees these arguments.
  [ -s "/opt/homebrew/opt/nvm/nvm.sh" ] && . "/opt/homebrew/opt/nvm/nvm.sh" "$@"
  [ -s "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm" ] && . "/opt/homebrew/opt/nvm/etc/bash_completion.d/nvm"
}

# --no-use keeps the node that is already on PATH.
nvm() {
  _nvm_load --no-use
  nvm "$@"
}

# Switches node to the version in the nearest .nvmrc, or to nvm's default
# version outside a project with a .nvmrc. nvm handles each spec that
# _nvm_installed_dir cannot resolve, and installs a missing .nvmrc version.
load-nvmrc() {
  # Skip in Flox environments where Node is managed externally
  if [ -n "$FLOX_ENV" ] || [ -n "$FLOX_ACTIVE_ENVIRONMENTS" ]; then
    return
  fi
  _nvm_node_dir
  local dir=$PWD current=$REPLY rc=$NVM_DIR/alias/default reverting=
  until [[ -z $dir || -f $dir/.nvmrc ]]; do dir=${dir%/*}; done
  if [[ -n $dir ]]; then
    rc=$dir/.nvmrc
  elif [[ -f $rc ]]; then
    reverting=1
  else
    return
  fi
  if _nvm_installed_dir "$(<$rc)"; then
    if [[ $current != $REPLY/bin ]]; then
      [[ -n $reverting ]] && echo "Reverting to nvm default version"
      _nvm_activate "$REPLY"
      echo "Now using node ${REPLY:t}"
    fi
    return
  fi

  (( $+functions[nvm_find_nvmrc] )) || _nvm_load --no-use
  local node_version="$(nvm version)"
  local nvmrc_path="$(nvm_find_nvmrc)"
  if [ -n "$nvmrc_path" ]; then
    local nvmrc_node_version=$(nvm version "$(cat "${nvmrc_path}")")
    if [ "$nvmrc_node_version" = "N/A" ]; then
      nvm install
    elif [ "$nvmrc_node_version" != "$node_version" ]; then
      nvm use
    fi
  elif [ "$(nvm version default)" != "N/A" ] && [ "$node_version" != "$(nvm version default)" ]; then
    echo "Reverting to nvm default version"
    nvm use default
  fi
}

# nvm.sh puts the default node on PATH when it loads, unless `node` already runs
# an nvm node. This does the same.
_nvm_node_dir
if [[ $REPLY != $NVM_DIR/versions/node/*/bin && -f $NVM_DIR/alias/default ]]; then
  if _nvm_installed_dir "$(<$NVM_DIR/alias/default)"; then
    _nvm_activate "$REPLY"
  else
    _nvm_load
  fi
fi
