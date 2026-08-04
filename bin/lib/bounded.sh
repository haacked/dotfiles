#!/usr/bin/env bash
# A deadline for commands that can block indefinitely. The SSH signing scripts
# run on git's every-signed-commit path and on zsh's precmd hook, where an
# unbounded ssh-add against a stalled agent, or a read of a key file on a
# wedged mount, turns into a hang with no output and no error.
#
# Usage: source "$lib_dir/bounded.sh"

# Runs "$@" with a deadline of $1 seconds, printing what it wrote to stdout and
# returning its exit status. On timeout, kills it and returns 124, the status
# timeout(1) uses. stderr is discarded; every caller here already did that.
#
# Callers use 2 seconds for agent probes, where a reachable agent answers in
# tens of milliseconds, and 10 for whole test invocations.
#
# Only for small, text-only output. `read` consumes a pipe a byte at a time, so
# capture cost scales with output size and a NUL in the output ends it early.
#
# timeout(1) itself would be the obvious tool, but it's Homebrew coreutils and
# git execs these scripts with whatever PATH it inherited. The command runs
# behind a process substitution rather than a plain redirect so this shell never
# blocks in open(). The trailing NUL is what `read -d ''` waits for, so reaching
# it means the command finished, and timing out is the only way to miss it.
# Don't infer that from read's own exit status instead: it is 1 for both cases
# under the bash 3.2 that /usr/bin/env resolves to without Homebrew on PATH.
run_bounded() {
  local deadline=$1 out pid rc=""
  shift
  # `|| _rc=$?` keeps a command that legitimately exits non-zero (ssh-add -l
  # returns 1 for an empty agent, 2 for an unreachable one) from tripping the
  # errexit these callers set, which would kill the subshell before it reports.
  # fd 3 is hardcoded because bash 3.2 has no {fd}< auto-allocation, so callers
  # must not hold it open across this function.
  exec 3< <({ _rc=0; "$@" || _rc=$?; printf '\0%s' "$_rc"; } 2>/dev/null)
  pid=$!
  if IFS= read -r -d '' -t "$deadline" out <&3; then
    # Expected to return non-zero: the status is written without a trailing
    # delimiter, so this read assigns and then hits EOF. The value matters, the
    # status doesn't. A missing or non-numeric one means the NUL came from the
    # command's own output rather than the end of the protocol, so the command
    # is still running and this is a timeout like any other.
    IFS= read -r -t "$deadline" rc <&3 || true
    exec 3<&-
    if [[ -z "$rc" || "$rc" == *[!0-9]* ]]; then
      pkill -P "$pid" 2>/dev/null
      kill -TERM "$pid" 2>/dev/null
      return 124
    fi
    printf '%s' "$out"
    return "$rc"
  fi
  exec 3<&-
  # $pid is the substitution's subshell, which forked the command, so the child
  # has to go first. Skipping it orphans a blocked process onto init, one per
  # call, for as long as whatever it is waiting on stays wedged.
  pkill -P "$pid" 2>/dev/null
  kill -TERM "$pid" 2>/dev/null
  return 124
}
