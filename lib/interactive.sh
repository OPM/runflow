#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Interactive shells: a prompt marker, job notifications and tab completion.
# Loaded by lib/runflow.sh when the shell is interactive: runflow --shell, or
# source runflow.bash at a prompt. No traps are set and nothing exits the
# shell; this run's jobs are those submitted from this shell.
#
# Settings: RUNFLOW_PROMPT, RUNFLOW_NOTIFY, RUNFLOW_NOTIFY_INTERVAL (see
# etc/defaults/runflow.conf)

_RUNFLOW_INTERACTIVE=true

# --- Prompt ------------------------------------------------------------------

# The marker before the prompt: (runflow SCHEDULER FLOW_VERSION[ dry-run])
runflow::prompt() {
  [[ "${RUNFLOW_PROMPT:-true}" == true ]] || return 0
  local scheduler dry=""
  scheduler=$(runflow::get_scheduler 2> /dev/null) || scheduler="?"
  runflow::dry_run && dry=" dry-run"
  printf '(runflow %s %s%s) ' "$scheduler" "$RUNFLOW_FLOW_VERSION" "$dry"
}

# --- Job notifications ---------------------------------------------------------

_RUNFLOW_NOTIFY_LAST=0
declare -gA _RUNFLOW_NOTIFIED=()

# Before each prompt: report jobs of this shell that finished since, at most
# every RUNFLOW_NOTIFY_INTERVAL seconds (each check asks the schedulers).
# Jobs whose end @wait or @cancel already reported are skipped.
runflow::notify() {
  local rc=$? now jobid status reported
  [[ "${RUNFLOW_NOTIFY:-true}" == true ]] || return $rc
  printf -v now '%(%s)T' -1
  (( now - _RUNFLOW_NOTIFY_LAST >= ${RUNFLOW_NOTIFY_INTERVAL:-5} )) || return $rc
  _RUNFLOW_NOTIFY_LAST=$now

  if [[ -f "$RUNFLOW_SESSION_FILE.reported" ]]; then
    while IFS= read -r reported; do
      [[ -z "$reported" ]] || _RUNFLOW_NOTIFIED[$reported]=1
    done < "$RUNFLOW_SESSION_FILE.reported"
  fi

  while IFS= read -r jobid; do
    [[ -n "$jobid" && -z "${_RUNFLOW_NOTIFIED[$jobid]:-}" ]] || continue
    runflow::parse_jobid "$jobid" 2> /dev/null || continue
    if [[ "$_RUNFLOW_JOB_ID" == dry* ]] ||
       ! runflow::load_queue_backend "$_RUNFLOW_JOB_SCHEDULER" > /dev/null 2>&1; then
      _RUNFLOW_NOTIFIED[$jobid]=1
      continue
    fi
    status=$(runflow::backend_job_status "$_RUNFLOW_JOB_ID" 2> /dev/null)
    case "$status" in
      COMPLETED|FAILED|CANCELLED)
        echo "[runflow] Job $jobid ${status,,}" >&2
        _RUNFLOW_NOTIFIED[$jobid]=1
        ;;
      UNKNOWN) _RUNFLOW_NOTIFIED[$jobid]=1 ;;
    esac
  done < <(runflow::session_jobs)
  return $rc
}

# --- Completion ------------------------------------------------------------------

# Flow version names: the named versions, then the executables in the search
# directories (no OPM check: completion must be fast)
runflow::complete_versions() {
  local dir exe entry
  {
    for entry in "${RUNFLOW_FLOW_VERSIONS[@]}"; do
      echo "${entry%%=*}"
    done
    while IFS= read -r dir; do
      for exe in "$dir"/flow*; do
        [[ -f "$exe" && -x "$exe" ]] && echo "${exe##*/}"
      done
    done < <(runflow::flow::search_dirs 2> /dev/null)
  } | sort -u
}

# Complete CUR as a value of KIND (see runflow::directive_option and
# runflow::directive_arguments), into COMPREPLY
runflow::complete_kind() {
  local kind="$1" cur="$2" file
  case "$kind" in
    version) mapfile -t COMPREPLY < <(compgen -W "$(runflow::complete_versions)" -- "$cur") ;;
    scheduler) mapfile -t COMPREPLY < <(compgen -W "auto lsf slurm pbs localq" -- "$cur") ;;
    job) mapfile -t COMPREPLY < <(compgen -W "$(runflow::session_jobs)" -- "$cur") ;;
    directive) mapfile -t COMPREPLY < <(compgen -A function -- "@${cur#@}") ;;
    deck)
      # Decks and directories
      compopt -o filenames 2> /dev/null
      while IFS= read -r file; do
        [[ -d "$file" || "$file" == *.DATA || "$file" == *.data ]] && COMPREPLY+=("$file")
      done < <(compgen -f -- "$cur")
      ;;
    command)
      compopt -o filenames 2> /dev/null
      mapfile -t COMPREPLY < <(compgen -c -f -- "$cur")
      ;;
    file)
      compopt -o filenames 2> /dev/null
      mapfile -t COMPREPLY < <(compgen -f -- "$cur")
      ;;
  esac
}

# Completion of the directives, runflow::setup and runflow. Directives compose
# (@submit -n 4 @mpi @flow ...): the nearest directive before the cursor
# decides. Job IDs contain ":", which bash treats as a word break, so the word
# being completed is taken from the command line itself.
runflow::complete() {
  local line=${COMP_LINE:0:COMP_POINT} cur prev i context="" words=() options=""
  cur=${line##*[[:space:]]}
  read -ra words <<< "${line%"$cur"}"
  prev=${words[${#words[@]} - 1]:-}
  COMPREPLY=()

  for (( i = ${#words[@]} - 1; i >= 0; i-- )); do
    case "${words[i]}" in
      @*) context=${words[i]#@}; break ;;
      runflow|*/runflow|runflow::setup) context=setup; break ;;
    esac
  done

  if [[ "$cur" == @* ]]; then
    mapfile -t COMPREPLY < <(compgen -A function -- "$cur")
    return 0
  fi

  # Options of the context and the kind of value each takes: declared by the
  # directives (runflow::directive_option); for runflow and runflow::setup,
  # their options and the directive settings
  local -A kinds=()
  local spec kind description name
  if [[ "$context" == setup ]]; then
    for name in -n -q --lsf-options --slurm-options --pbs-options --localq-options; do
      kinds[$name]=text
    done
    for name in $(runflow::directives_with_options); do
      kinds[--$name-options]=text
    done
    for name in "${!_RUNFLOW_SETTING_VAR[@]}"; do
      kinds[--$name]=${_RUNFLOW_SETTING_KIND[$name]:-text}
    done
    kinds[-s]=scheduler kinds[--scheduler]=scheduler kinds[--depends-on]=job kinds[--directives]=file
    options="${!kinds[*]} --dry-run"
    [[ "${words[0]}" == runflow::setup ]] || options+=" -c --shell --jobs --jobs=all --library -h"
  elif [[ -n "$context" ]]; then
    while IFS=$'\t' read -r spec kind description; do
      [[ -n "$spec" ]] || continue
      for name in $(runflow::option_names "$spec"); do
        options+=" $name"
        [[ "$kind" == - ]] || kinds[$name]=$kind
      done
    done <<< "${_RUNFLOW_DIRECTIVE_OPTION_LIST[$context]:-}"
  fi

  if [[ -n "${kinds[$prev]:-}" ]]; then
    runflow::complete_kind "${kinds[$prev]}" "$cur"
  elif [[ "$cur" == -* && -n "$options" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
  elif [[ "$context" == setup ]]; then
    runflow::complete_kind file "$cur"
  else
    runflow::complete_kind "${_RUNFLOW_DIRECTIVE_ARGS[$context]:-file}" "$cur"
  fi

  # Bash replaces only the part after the last ":" of a job ID
  if [[ "$cur" == *:* ]]; then
    local prefix=${cur%"${cur##*:}"}
    for i in "${!COMPREPLY[@]}"; do
      COMPREPLY[i]=${COMPREPLY[i]#"$prefix"}
    done
  fi
  return 0
}

# Register the completion for every loaded directive (again after
# runflow::use loads more), runflow::setup and runflow
runflow::register_completion() {
  local name
  for name in "${_RUNFLOW_DIRECTIVE_ORDER[@]}"; do
    complete -F runflow::complete "@$name"
  done
  complete -F runflow::complete runflow::setup runflow
}

# --- Startup ------------------------------------------------------------------------

runflow::register_completion

# The marker goes first in the prompt, once (also if the library is sourced again)
if [[ "${PS1:-}" != *'$(runflow::prompt)'* ]]; then
  PS1='$(runflow::prompt)'"${PS1:-\$ }"
fi

# Notifications run last, keeping $? for the rest of the prompt
if [[ "$(declare -p PROMPT_COMMAND 2> /dev/null)" == "declare -a"* ]]; then
  [[ " ${PROMPT_COMMAND[*]} " == *" runflow::notify "* ]] || PROMPT_COMMAND+=(runflow::notify)
elif [[ "${PROMPT_COMMAND:-}" != *runflow::notify* ]]; then
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }runflow::notify"
fi
