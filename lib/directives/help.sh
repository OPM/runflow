#!/usr/bin/env bash
# @help - list the directives, or show one directive's help (core directive)

opmexec::directive help "[@DIRECTIVE]" "List the directives, or show the options of one"
opmexec::directive_arguments directive

#   @help            every loaded directive, with its summary
#   @help @flow      the options of @flow (also @NAME --help, except for
#                    @flow and @flowpy, which pass it on)
@help() {
  opmexec::help_requested help "$@" && return 0

  if [[ $# -eq 0 ]]; then
    echo "Directives:"
    opmexec::directive_help
    echo
    echo "@help @NAME: its options (also @NAME --help, but @flow and @flowpy pass --help to Flow and Python)."
    echo "Full reference: $(opmexec::man_command)"
    return 0
  fi

  local name=${1#@}
  if [[ -z "${_OPMEXEC_DIRECTIVE_KIND[$name]:-}" ]]; then
    opmexec::error "@help: unknown directive: @$name (@help lists them)"
    return 1
  fi
  opmexec::directive_details "$name"
}
