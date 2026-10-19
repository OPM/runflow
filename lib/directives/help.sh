#!/usr/bin/env bash
# @help - list the directives, or show one directive's help (core directive)

opmexec::directive help "[@DIRECTIVE]" "List the directives, or show the options of one"
opmexec::directive_arguments directive

#   @help            every loaded directive, with its summary
#   @help @flow      the options of @flow (the only help of a directive:
#                    @flow --help is Flow's)
@help() {

  if [[ $# -eq 0 ]]; then
    echo "Directives:"
    opmexec::directive_help
    echo
    echo "@help @NAME: the options of one."
    echo "Full reference: $(opmexec::man_command)"
    return 0
  fi

  if [[ "$1" == -* ]]; then
    opmexec::unknown_option help "$1" "@help @help"
    return 1
  fi
  local name=${1#@}
  if [[ -z "${_OPMEXEC_DIRECTIVE_KIND[$name]:-}" ]]; then
    opmexec::error "@help: unknown directive: @$name (@help lists them)"
    return 1
  fi
  opmexec::directive_details "$name"
}
