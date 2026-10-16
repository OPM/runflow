#!/usr/bin/env bash
# @flowpy - run the Python of a Flow version, with its opm bindings (bundled
# extension; a later directory in OPMEXEC_DIRECTIVE_PATH may replace it).
# Uses the opmexec::flow:: helpers of the @flow extension (flow.sh): the
# version is chosen as for @flow, the Python as described in
# opmexec::flow::python_info.

opmexec::directive flowpy "[-v VERSION] script.py|-c CODE|-m MODULE [ARGS...]" \
  "Run the Python of a Flow version, with its opm bindings" \
  "Python interpreter options for every @flowpy, e.g. \"-u\""
opmexec::directive_setting flowpy-version OPMEXEC_FLOWPY_VERSION \
  "Flow version whose Python every @flowpy without -v uses (default: --flow-version)" version
opmexec::directive_option "-v, --flow-version VERSION" version \
  "Flow version whose Python and opm bindings to use (as for @flow; default: --flowpy-version, else --flow-version)"
opmexec::directive_option "--help, --version" - \
  "Python's own (everything else goes to Python too); opmexec's help on @flowpy: @help @flowpy"
opmexec::directive_option "--" - \
  "End of @flowpy's options: the rest goes to Python"
opmexec::directive_arguments file

# Build the command line of @flowpy into _OPMEXEC_ARGV, so that @mpi can
# launch it too
opmexec::command_flowpy() {
  local version
  _OPMEXEC_ARGV=()

  # Only -v is ours; everything else (script, -c, -m, ...) goes to Python
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -v|--flow-version) opmexec::has_value @flowpy "$@" || return 1; version="$2"; shift 2 ;;
      --) shift; break ;;
      *) break ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    opmexec::error "@flowpy: script, -c CODE or -m MODULE required"
    return 1
  fi
  if ! declare -F opmexec::flow::python_info > /dev/null; then
    opmexec::error "@flowpy: needs the opmexec::flow:: helpers of the @flow extension (flow.sh)"
    return 1
  fi

  version=${version:-${OPMEXEC_FLOWPY_VERSION:-$OPMEXEC_FLOW_VERSION}}
  local problem="" exe=""
  opmexec::flow::find "$version" && exe=$_OPMEXEC_FLOW_FOUND
  opmexec::flow::python_info "$version" "$exe"

  # A Flow version not found is a problem, unless the map names its Python
  if [[ -z "$exe" && "$_OPMEXEC_FLOW_PYTHON_FROM" != map ]]; then
    problem=$_OPMEXEC_FLOW_PROBLEM
  elif [[ "$OPMEXEC_FLOW_PYTHONPATH" == auto && -z "$_OPMEXEC_FLOW_BINDINGS" ]]; then
    problem="no opm Python bindings found for flow $version"
    [[ "$_OPMEXEC_FLOW_EXE" == "$version" ]] || problem+=" ($_OPMEXEC_FLOW_EXE)"
    problem+="; install them with Flow, or set OPMEXEC_FLOW_PYTHONPATH"
  elif [[ -z "$_OPMEXEC_FLOW_INTERPRETER" ]]; then
    problem="Python ${_OPMEXEC_FLOW_PYTHON:-3} not found (needed by flow $version); install it, or set OPMEXEC_FLOW_PYTHON_MAP"
  elif [[ -n "$_OPMEXEC_FLOW_MODULE" ]] &&
       ! opmexec::flow::module_loadable "$_OPMEXEC_FLOW_INTERPRETER" "$_OPMEXEC_FLOW_MODULE"; then
    problem="$_OPMEXEC_FLOW_INTERPRETER cannot import the opm bindings of flow $version: ${_OPMEXEC_FLOW_MODULE##*/} is for another Python; set OPMEXEC_FLOW_PYTHON_MAP or OPMEXEC_FLOW_PYTHONPATH"
  fi
  if [[ -n "$problem" ]]; then
    opmexec::dry_run || { opmexec::error "@flowpy: $problem"; return 1; }
    opmexec::dry "warning: $problem"
  fi

  # For the record (stderr: the terminal, or the job's log), as @flow does:
  # which interpreter runs, and its bindings; stdout stays Python's
  local interpreter=${_OPMEXEC_FLOW_INTERPRETER:-python${_OPMEXEC_FLOW_PYTHON:-3}}
  local record="flow $version: $interpreter; $(opmexec::flow::python_summary)"
  if opmexec::dry_run; then
    opmexec::dry "$record"
  else
    opmexec::info "@flowpy: $record"
  fi

  local environment=()
  [[ -z "$_OPMEXEC_FLOW_BINDINGS" ]] ||
    environment=(env "PYTHONPATH=$_OPMEXEC_FLOW_BINDINGS${PYTHONPATH:+:$PYTHONPATH}")

  # Interpreter options for every @flowpy (--flowpy-options), then the script
  opmexec::directive_options flowpy || return 1
  _OPMEXEC_ARGV=("${environment[@]}" "$interpreter" "${_OPMEXEC_WORDS[@]}" "$@")
}

# Run Python as Flow's: the interpreter its opm bindings were built for, with
# the bindings in PYTHONPATH, e.g. to prepare or post-process with opm.io.
#   @flowpy [-v VERSION] script.py [ARGS...]
#   @mpi -n 4 @flowpy parallel_script.py            (e.g. with mpi4py)
#   @wait @submit @flowpy postprocess.py CASE.DATA
@flowpy() {
  opmexec::command_flowpy "$@" || return 1

  if opmexec::dry_run; then
    opmexec::dry "run: $(opmexec::quoted "${_OPMEXEC_ARGV[@]}")"
    return 0
  fi

  "${_OPMEXEC_ARGV[@]}"
}
