#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @help - list the directives, or show one directive's help (core directive)

runflow::directive help "[@DIRECTIVE]" "List the directives, or show the options of one"
runflow::directive_arguments directive

#   @help            every loaded directive, with its summary
#   @help @flow      the options of @flow (the only help of a directive:
#                    @flow --help is Flow's)
@help() {

  if [[ $# -eq 0 ]]; then
    echo "Directives:"
    runflow::directive_help
    echo
    echo "@help @NAME: the options of one."
    echo "Full reference: $(runflow::man_command)"
    return 0
  fi

  if [[ "$1" == -* ]]; then
    runflow::unknown_option help "$1" "@help @help"
    return 1
  fi
  local name=${1#@}
  if [[ -z "${_RUNFLOW_DIRECTIVE_KIND[$name]:-}" ]]; then
    runflow::error "@help: unknown directive: @$name (@help lists them)"
    return 1
  fi
  runflow::directive_details "$name"
}
