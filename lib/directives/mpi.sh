#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @mpi - run a program or launchable directive with MPI (core directive)

flowrun::directive mpi "[-n NP] [-o LAUNCHER_OPTIONS] command|@directive ..." \
  "Run a program, or a directive such as @flow, with MPI" \
  "MPI launcher options for every @mpi, before its -o options"
flowrun::directive_option "-n, --np NP" text \
  "Number of MPI ranks (default: flowrun -n; inside a job, the job's -n)"
flowrun::directive_option "-o, --options OPTS" text \
  "Launcher options, after those of --mpi-options (e.g. \"--map-by core\")"
flowrun::directive_arguments command

# Run a command or directive with MPI, through the launcher configured for
# where it runs: FLOWRUN_MPI_LAUNCHER_<SCHEDULER> inside a job (the job's
# scheduler is in FLOWRUN_JOB_SCHEDULER), FLOWRUN_MPI_LAUNCHER_LOCAL otherwise.
#   @mpi [-n NP] [-o LAUNCHER_OPTIONS] command|directive [args...]
@mpi() {
  local np launcher_options
  
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--np) flowrun::has_value @mpi "$@" || return 1; np="$2"; shift 2 ;;
      -o|--options) flowrun::has_value @mpi "$@" || return 1; launcher_options="${launcher_options:+$launcher_options }$2"; shift 2 ;;
      --) shift; break ;;
      -*)
        flowrun::unknown_option mpi "$1" "use -- before a command that starts with -"
        return 1
        ;;
      *) break ;;
    esac
  done
  
  if [[ $# -eq 0 ]]; then
    flowrun::error "@mpi: command required"
    return 1
  fi
  
  np=${np:-${FLOWRUN_NP:-1}}
  if ! [[ "$np" =~ ^[1-9][0-9]*$ ]]; then
    flowrun::error "@mpi: number of processes must be a positive integer (got: $np)"
    return 1
  fi
  
  # The command to launch; a directive provides it via flowrun::command_<name>
  local command=()
  if [[ "$1" == @* ]]; then
    local builder="flowrun::command_${1#@}"
    if ! declare -F "$builder" > /dev/null; then
      flowrun::error "@mpi: $1 cannot run under @mpi (it provides no flowrun::command_${1#@}; @flow and @flowpy can)"
      return 1
    fi
    shift
    "$builder" "$@" || return 1
    command=("${_FLOWRUN_ARGV[@]}")
  else
    command=("$@")
  fi
  
  # Launcher for this context ({np} becomes the number of processes), then
  # workflow (flowrun --mpi-options) and per-call (-o) launcher options
  local context="${FLOWRUN_JOB_SCHEDULER:-local}"
  local launcher_var="FLOWRUN_MPI_LAUNCHER_${context^^}"
  [[ -n "${!launcher_var:-}" ]] || launcher_var=FLOWRUN_MPI_LAUNCHER_LOCAL
  local template="${!launcher_var:-}"
  
  flowrun::split_options "${template//\{np\}/$np}" "$launcher_var" || return 1
  local launcher=("${_FLOWRUN_WORDS[@]}")
  if [[ ${#launcher[@]} -eq 0 ]]; then
    flowrun::error "@mpi: no MPI launcher configured (set $launcher_var)"
    return 1
  fi
  flowrun::directive_options mpi || return 1
  launcher+=("${_FLOWRUN_WORDS[@]}")
  flowrun::split_options "$launcher_options" "@mpi -o" || return 1
  launcher+=("${_FLOWRUN_WORDS[@]}")
  
  if ! command -v "${launcher[0]}" > /dev/null; then
    if ! flowrun::dry_run; then
      flowrun::error "@mpi: MPI launcher not found: ${launcher[0]} (set $launcher_var)"
      return 1
    fi
    flowrun::dry "warning: MPI launcher not found: ${launcher[0]} ($launcher_var)"
  fi
  
  if flowrun::dry_run; then
    flowrun::dry "run: $(flowrun::quoted "${launcher[@]}" "${command[@]}")"
    return 0
  fi
  
  "${launcher[@]}" "${command[@]}"
}
