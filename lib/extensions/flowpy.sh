#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @flowpy - run the Python of a Flow version, with its opm bindings (bundled
# extension; a later directory in FLOWRUN_DIRECTIVE_PATH may replace it).
# Uses the flowrun::flow:: helpers of the @flow extension (flow.sh): the
# version is chosen as for @flow, the Python as described in
# flowrun::flow::python_info.

flowrun::directive flowpy "[-v VERSION] script.py|-c CODE|-m MODULE [ARGS...]" \
  "Run the Python of a Flow version, with its opm bindings" \
  "Python interpreter options for every @flowpy, e.g. \"-u\""
flowrun::directive_setting flowpy-version FLOWRUN_FLOWPY_VERSION \
  "Flow version whose Python every @flowpy without -v uses (default: --flow-version)" version
flowrun::directive_option "-v, --flow-version VERSION" version \
  "Flow version whose Python and opm bindings to use (as for @flow; default: --flowpy-version, else --flow-version)"
flowrun::directive_option "--" - \
  "End of @flowpy's options: the rest goes to Python"
flowrun::directive_arguments file

# Build the command line of @flowpy into _FLOWRUN_ARGV, so that @mpi can
# launch it too
flowrun::command_flowpy() {
  local version
  _FLOWRUN_ARGV=()

  # Only -v is ours; everything else (script, -c, -m, ...) goes to Python
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--flow-version) flowrun::has_value @flowpy "$@" || return 1; version="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    flowrun::error "@flowpy: script, -c CODE or -m MODULE required"
    return 1
  fi
  if ! declare -F flowrun::flow::python_info > /dev/null; then
    flowrun::error "@flowpy: needs the flowrun::flow:: helpers of the @flow extension (flow.sh)"
    return 1
  fi

  version=${version:-${FLOWRUN_FLOWPY_VERSION:-$FLOWRUN_FLOW_VERSION}}
  local problem="" exe=""
  flowrun::flow::find "$version" && exe=$_FLOWRUN_FLOW_FOUND
  flowrun::flow::python_info "$version" "$exe"

  # A Flow version not found is a problem, unless the map names its Python
  if [[ -z "$exe" && "$_FLOWRUN_FLOW_PYTHON_FROM" != map ]]; then
    problem=$_FLOWRUN_FLOW_PROBLEM
  elif [[ "$FLOWRUN_FLOW_PYTHONPATH" == auto && -z "$_FLOWRUN_FLOW_BINDINGS" ]]; then
    problem="no opm Python bindings found for flow $version"
    [[ "$_FLOWRUN_FLOW_EXE" == "$version" ]] || problem+=" ($_FLOWRUN_FLOW_EXE)"
    problem+="; install them with Flow, or set FLOWRUN_FLOW_PYTHONPATH"
  elif [[ -z "$_FLOWRUN_FLOW_INTERPRETER" ]]; then
    problem="Python ${_FLOWRUN_FLOW_PYTHON:-3} not found (needed by flow $version); install it, or set FLOWRUN_FLOW_PYTHON_MAP"
  elif [[ -n "$_FLOWRUN_FLOW_MODULE" ]] &&
       ! flowrun::flow::module_loadable "$_FLOWRUN_FLOW_INTERPRETER" "$_FLOWRUN_FLOW_MODULE"; then
    problem="$_FLOWRUN_FLOW_INTERPRETER cannot import the opm bindings of flow $version: ${_FLOWRUN_FLOW_MODULE##*/} is for another Python; set FLOWRUN_FLOW_PYTHON_MAP or FLOWRUN_FLOW_PYTHONPATH"
  fi
  if [[ -n "$problem" ]]; then
    flowrun::dry_run || { flowrun::error "@flowpy: $problem"; return 1; }
    flowrun::dry "warning: $problem"
  fi

  # For the record (stderr: the terminal, or the job's log), as @flow does:
  # which interpreter runs, and its bindings; stdout stays Python's
  local interpreter=${_FLOWRUN_FLOW_INTERPRETER:-python${_FLOWRUN_FLOW_PYTHON:-3}}
  local record="flow $version: $interpreter; $(flowrun::flow::python_summary)"
  if flowrun::dry_run; then
    flowrun::dry "$record"
  else
    flowrun::info "@flowpy: $record"
  fi

  local environment=()
  [[ -z "$_FLOWRUN_FLOW_BINDINGS" ]] ||
    environment=(env "PYTHONPATH=$_FLOWRUN_FLOW_BINDINGS${PYTHONPATH:+:$PYTHONPATH}")

  # Interpreter options for every @flowpy (--flowpy-options), then the script
  flowrun::directive_options flowpy || return 1
  _FLOWRUN_ARGV=("${environment[@]}" "$interpreter" "${_FLOWRUN_WORDS[@]}" "$@")
}

# Run Python as Flow's: the interpreter its opm bindings were built for, with
# the bindings in PYTHONPATH, e.g. to prepare or post-process with opm.io.
#   @flowpy [-v VERSION] script.py [ARGS...]
#   @mpi -n 4 @flowpy parallel_script.py            (e.g. with mpi4py)
#   @wait @submit @flowpy postprocess.py CASE.DATA
@flowpy() {
  flowrun::command_flowpy "$@" || return 1

  if flowrun::dry_run; then
    flowrun::dry "run: $(flowrun::quoted "${_FLOWRUN_ARGV[@]}")"
    return 0
  fi

  "${_FLOWRUN_ARGV[@]}"
}
