#!/usr/bin/env bash
# @mpi - run a program or launchable directive with MPI (core directive)

opmexec::directive mpi "[-n NP] [-o LAUNCHER_OPTIONS] command|@directive ..." \
  "Run a program, or a directive such as @flow, with MPI" \
  "MPI launcher options for every @mpi, before its -o options"
opmexec::directive_option "-n, --np NP" text \
  "Number of MPI ranks (default: opmexec -n; inside a job, the job's -n)"
opmexec::directive_option "-o, --options OPTS" text \
  "Launcher options, after those of --mpi-options (e.g. \"--map-by core\")"
opmexec::directive_arguments command

# Run a command or directive with MPI, through the launcher configured for
# where it runs: OPMEXEC_MPI_LAUNCHER_<SCHEDULER> inside a job (the job's
# scheduler is in OPMEXEC_JOB_SCHEDULER), OPMEXEC_MPI_LAUNCHER_LOCAL otherwise.
#   @mpi [-n NP] [-o LAUNCHER_OPTIONS] command|directive [args...]
@mpi() {
  opmexec::help_requested mpi "$@" && return 0
  local np launcher_options
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--np) opmexec::has_value @mpi "$@" || return 1; np="$2"; shift 2 ;;
      -o|--options) opmexec::has_value @mpi "$@" || return 1; launcher_options="${launcher_options:+$launcher_options }$2"; shift 2 ;;
      --) shift; break ;;
      -*)
        opmexec::error "@mpi: unknown option: $1 (use -- before a command that starts with -)"
        return 1
        ;;
      *) break ;;
    esac
  done
  
  if [[ $# -eq 0 ]]; then
    opmexec::error "@mpi: command required"
    return 1
  fi
  
  np=${np:-${OPMEXEC_NP:-1}}
  if ! [[ "$np" =~ ^[1-9][0-9]*$ ]]; then
    opmexec::error "@mpi: number of processes must be a positive integer (got: $np)"
    return 1
  fi
  
  # The command to launch; a directive provides it via opmexec::command_<name>
  local command=()
  if [[ "$1" == @* ]]; then
    local builder="opmexec::command_${1#@}"
    if ! declare -F "$builder" > /dev/null; then
      opmexec::error "@mpi: $1 cannot run under @mpi (it provides no opmexec::command_${1#@}; @flow and @flowpy can)"
      return 1
    fi
    shift
    "$builder" "$@" || return 1
    command=("${_OPMEXEC_ARGV[@]}")
  else
    command=("$@")
  fi
  
  # Launcher for this context ({np} becomes the number of processes), then
  # workflow (opmexec --mpi-options) and per-call (-o) launcher options
  local context="${OPMEXEC_JOB_SCHEDULER:-local}"
  local launcher_var="OPMEXEC_MPI_LAUNCHER_${context^^}"
  [[ -n "${!launcher_var:-}" ]] || launcher_var=OPMEXEC_MPI_LAUNCHER_LOCAL
  local template="${!launcher_var:-}"
  
  opmexec::split_options "${template//\{np\}/$np}" "$launcher_var" || return 1
  local launcher=("${_OPMEXEC_WORDS[@]}")
  if [[ ${#launcher[@]} -eq 0 ]]; then
    opmexec::error "@mpi: no MPI launcher configured (set $launcher_var)"
    return 1
  fi
  opmexec::directive_options mpi || return 1
  launcher+=("${_OPMEXEC_WORDS[@]}")
  opmexec::split_options "$launcher_options" "@mpi -o" || return 1
  launcher+=("${_OPMEXEC_WORDS[@]}")
  
  if ! command -v "${launcher[0]}" > /dev/null; then
    if ! opmexec::dry_run; then
      opmexec::error "@mpi: MPI launcher not found: ${launcher[0]} (set $launcher_var)"
      return 1
    fi
    opmexec::dry "warning: MPI launcher not found: ${launcher[0]} ($launcher_var)"
  fi
  
  if opmexec::dry_run; then
    opmexec::dry "run: $(opmexec::quoted "${launcher[@]}" "${command[@]}")"
    return 0
  fi
  
  "${launcher[@]}" "${command[@]}"
}
