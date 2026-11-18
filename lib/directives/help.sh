#!/usr/bin/env bash
# @help - list the directives, or show one directive's help (core directive)

flowrun::directive help "[@DIRECTIVE]" "List the directives, or show the options of one"
flowrun::directive_arguments directive

#   @help            every loaded directive, with its summary
#   @help @flow      the options of @flow (the only help of a directive:
#                    @flow --help is Flow's)
@help() {

  if [[ $# -eq 0 ]]; then
    echo "Directives:"
    flowrun::directive_help
    echo
    echo "@help @NAME: the options of one."
    echo "Full reference: $(flowrun::man_command)"
    return 0
  fi

  if [[ "$1" == -* ]]; then
    flowrun::unknown_option help "$1" "@help @help"
    return 1
  fi
  local name=${1#@}
  if [[ -z "${_FLOWRUN_DIRECTIVE_KIND[$name]:-}" ]]; then
    flowrun::error "@help: unknown directive: @$name (@help lists them)"
    return 1
  fi
  flowrun::directive_details "$name"
}
