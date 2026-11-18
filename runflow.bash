#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Load the runflow directives into a bash script:
#   source runflow.bash
# bash finds this file through PATH when runflow is installed (the runflow
# directory is in PATH). It loads lib/runflow.sh from the same directory.
# Without PATH lookup: source "$(runflow --library)"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "runflow.bash is meant to be sourced: source runflow.bash" >&2
  exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib/runflow.sh" || return 1

# At a prompt, options may be given to source (in a script they would be the
# script's own arguments; use runflow::setup there):
#   source runflow.bash -s localq --flow-version flowrc47
if [[ $- == *i* && $# -gt 0 ]]; then
  runflow::setup "$@" || return 1
fi

# At a prompt (also runflow --shell): runflow and its man page, if not there
# yet. A MANPATH ending in ":" keeps the system's pages (man-db, macOS man).
# Scripts keep their PATH: the library has no side effects there.
if [[ $- == *i* ]]; then
  [[ ":$PATH:" == *":$RUNFLOW_HOME:"* ]] || PATH="$RUNFLOW_HOME:$PATH"
  [[ ":${MANPATH:-}:" == *":$RUNFLOW_HOME/man:"* ]] ||
    export MANPATH="$RUNFLOW_HOME/man:${MANPATH:-}"
fi
