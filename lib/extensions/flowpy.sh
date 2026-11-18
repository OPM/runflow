#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @flowpy - run the Python of a Flow version, with its opm bindings (bundled
# extension; a later directory in RUNFLOW_DIRECTIVE_PATH may replace it).
# Uses the runflow::flow:: helpers of the @flow extension (flow.sh): the
# version is chosen as for @flow, the Python as described in
# runflow::flow::python_info.

runflow::directive flowpy "[-v VERSION] script.py|-c CODE|-m MODULE [ARGS...]" \
  "Run the Python of a Flow version, with its opm bindings" \
  "Python interpreter options for every @flowpy, e.g. \"-u\""
runflow::directive_setting flowpy-version RUNFLOW_FLOWPY_VERSION \
  "Flow version whose Python every @flowpy without -v uses (default: --flow-version)" version
runflow::directive_option "-v, --flow-version VERSION" version \
  "Flow version whose Python and opm bindings to use (as for @flow; default: --flowpy-version, else --flow-version)"
runflow::directive_option "--" - \
  "End of @flowpy's options: the rest goes to Python"
runflow::directive_arguments file

# Build the command line of @flowpy into _RUNFLOW_ARGV, so that @mpi can
# launch it too
runflow::command_flowpy() {
  local version
  _RUNFLOW_ARGV=()

  # Only -v is ours; everything else (script, -c, -m, ...) goes to Python
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--flow-version) runflow::has_value @flowpy "$@" || return 1; version="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    runflow::error "@flowpy: script, -c CODE or -m MODULE required"
    return 1
  fi
  if ! declare -F runflow::flow::python_info > /dev/null; then
    runflow::error "@flowpy: needs the runflow::flow:: helpers of the @flow extension (flow.sh)"
    return 1
  fi

  version=${version:-${RUNFLOW_FLOWPY_VERSION:-$RUNFLOW_FLOW_VERSION}}
  local problem="" exe=""
  runflow::flow::find "$version" && exe=$_RUNFLOW_FLOW_FOUND
  runflow::flow::python_info "$version" "$exe"

  # A Flow version not found is a problem, unless the map names its Python
  if [[ -z "$exe" && "$_RUNFLOW_FLOW_PYTHON_FROM" != map ]]; then
    problem=$_RUNFLOW_FLOW_PROBLEM
  elif [[ "$RUNFLOW_FLOW_PYTHONPATH" == auto && -z "$_RUNFLOW_FLOW_BINDINGS" ]]; then
    problem="no opm Python bindings found for flow $version"
    [[ "$_RUNFLOW_FLOW_EXE" == "$version" ]] || problem+=" ($_RUNFLOW_FLOW_EXE)"
    problem+="; install them with Flow, or set RUNFLOW_FLOW_PYTHONPATH"
  elif [[ -z "$_RUNFLOW_FLOW_INTERPRETER" ]]; then
    problem="Python ${_RUNFLOW_FLOW_PYTHON:-3} not found (needed by flow $version); install it, or set RUNFLOW_FLOW_PYTHON_MAP"
  elif [[ -n "$_RUNFLOW_FLOW_MODULE" ]] &&
       ! runflow::flow::module_loadable "$_RUNFLOW_FLOW_INTERPRETER" "$_RUNFLOW_FLOW_MODULE"; then
    problem="$_RUNFLOW_FLOW_INTERPRETER cannot import the opm bindings of flow $version: ${_RUNFLOW_FLOW_MODULE##*/} is for another Python; set RUNFLOW_FLOW_PYTHON_MAP or RUNFLOW_FLOW_PYTHONPATH"
  fi
  if [[ -n "$problem" ]]; then
    runflow::dry_run || { runflow::error "@flowpy: $problem"; return 1; }
    runflow::dry "warning: $problem"
  fi

  # For the record (stderr: the terminal, or the job's log), as @flow does:
  # which interpreter runs, and its bindings; stdout stays Python's
  local interpreter=${_RUNFLOW_FLOW_INTERPRETER:-python${_RUNFLOW_FLOW_PYTHON:-3}}
  local record="flow $version: $interpreter; $(runflow::flow::python_summary)"
  if runflow::dry_run; then
    runflow::dry "$record"
  else
    runflow::info "@flowpy: $record"
  fi

  local environment=()
  [[ -z "$_RUNFLOW_FLOW_BINDINGS" ]] ||
    environment=(env "PYTHONPATH=$_RUNFLOW_FLOW_BINDINGS${PYTHONPATH:+:$PYTHONPATH}")

  # Interpreter options for every @flowpy (--flowpy-options), then the script
  runflow::directive_options flowpy || return 1
  _RUNFLOW_ARGV=("${environment[@]}" "$interpreter" "${_RUNFLOW_WORDS[@]}" "$@")
}

# Run Python as Flow's: the interpreter its opm bindings were built for, with
# the bindings in PYTHONPATH, e.g. to prepare or post-process with opm.io.
#   @flowpy [-v VERSION] script.py [ARGS...]
#   @mpi -n 4 @flowpy parallel_script.py            (e.g. with mpi4py)
#   @wait @submit @flowpy postprocess.py CASE.DATA
@flowpy() {
  runflow::command_flowpy "$@" || return 1

  if runflow::dry_run; then
    runflow::dry "run: $(runflow::quoted "${_RUNFLOW_ARGV[@]}")"
    return 0
  fi

  "${_RUNFLOW_ARGV[@]}"
}
