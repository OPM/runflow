#!/usr/bin/env bash
# Load the flowrun directives into a bash script:
#   source flowrun.bash
# bash finds this file through PATH when flowrun is installed (the flowrun
# directory is in PATH). It loads lib/flowrun.sh from the same directory.
# Without PATH lookup: source "$(flowrun --library)"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "flowrun.bash is meant to be sourced: source flowrun.bash" >&2
  exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib/flowrun.sh" || return 1

# At a prompt, options may be given to source (in a script they would be the
# script's own arguments; use flowrun::setup there):
#   source flowrun.bash -s localq --flow-version flowrc47
if [[ $- == *i* && $# -gt 0 ]]; then
  flowrun::setup "$@" || return 1
fi

# At a prompt (also flowrun --shell): flowrun and its man page, if not there
# yet. A MANPATH ending in ":" keeps the system's pages (man-db, macOS man).
# Scripts keep their PATH: the library has no side effects there.
if [[ $- == *i* ]]; then
  [[ ":$PATH:" == *":$FLOWRUN_HOME:"* ]] || PATH="$FLOWRUN_HOME:$PATH"
  [[ ":${MANPATH:-}:" == *":$FLOWRUN_HOME/man:"* ]] ||
    export MANPATH="$FLOWRUN_HOME/man:${MANPATH:-}"
fi
