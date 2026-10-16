#!/usr/bin/env bash
# Load the opmexec directives into a bash script:
#   source opmexec.bash
# bash finds this file through PATH when opmexec is installed (the opmexec
# directory is in PATH). It loads lib/opmexec.sh from the same directory.
# Without PATH lookup: source "$(opmexec --library)"

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  echo "opmexec.bash is meant to be sourced: source opmexec.bash" >&2
  exit 1
fi

source "$(dirname "${BASH_SOURCE[0]}")/lib/opmexec.sh" || return 1

# At a prompt, options may be given to source (in a script they would be the
# script's own arguments; use opmexec::setup there):
#   source opmexec.bash -s localq --flow-version flowrc47
if [[ $- == *i* && $# -gt 0 ]]; then
  opmexec::setup "$@" || return 1
fi
