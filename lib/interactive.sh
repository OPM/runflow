#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Interactive shells: a prompt marker, job notifications and tab completion.
# Loaded by lib/flowrun.sh when the shell is interactive: flowrun --shell, or
# source flowrun.bash at a prompt. No traps are set and nothing exits the
# shell; this run's jobs are those submitted from this shell.
#
# Settings: FLOWRUN_PROMPT, FLOWRUN_NOTIFY, FLOWRUN_NOTIFY_INTERVAL (see
# etc/defaults/flowrun.conf)

_FLOWRUN_INTERACTIVE=true

# --- Prompt ------------------------------------------------------------------

# The marker before the prompt: (flowrun SCHEDULER FLOW_VERSION[ dry-run])
flowrun::prompt() {
  [[ "${FLOWRUN_PROMPT:-true}" == true ]] || return 0
  local scheduler dry=""
  scheduler=$(flowrun::get_scheduler 2> /dev/null) || scheduler="?"
  flowrun::dry_run && dry=" dry-run"
  printf '(flowrun %s %s%s) ' "$scheduler" "$FLOWRUN_FLOW_VERSION" "$dry"
}

# --- Job notifications ---------------------------------------------------------

_FLOWRUN_NOTIFY_LAST=0
declare -gA _FLOWRUN_NOTIFIED=()

# Before each prompt: report jobs of this shell that finished since, at most
# every FLOWRUN_NOTIFY_INTERVAL seconds (each check asks the schedulers).
# Jobs whose end @wait or @cancel already reported are skipped.
flowrun::notify() {
  local rc=$? now jobid status reported
  [[ "${FLOWRUN_NOTIFY:-true}" == true ]] || return $rc
  printf -v now '%(%s)T' -1
  (( now - _FLOWRUN_NOTIFY_LAST >= ${FLOWRUN_NOTIFY_INTERVAL:-5} )) || return $rc
  _FLOWRUN_NOTIFY_LAST=$now

  if [[ -f "$FLOWRUN_SESSION_FILE.reported" ]]; then
    while IFS= read -r reported; do
      [[ -z "$reported" ]] || _FLOWRUN_NOTIFIED[$reported]=1
    done < "$FLOWRUN_SESSION_FILE.reported"
  fi

  while IFS= read -r jobid; do
    [[ -n "$jobid" && -z "${_FLOWRUN_NOTIFIED[$jobid]:-}" ]] || continue
    flowrun::parse_jobid "$jobid" 2> /dev/null || continue
    if [[ "$_FLOWRUN_JOB_ID" == dry* ]] ||
       ! flowrun::load_queue_backend "$_FLOWRUN_JOB_SCHEDULER" > /dev/null 2>&1; then
      _FLOWRUN_NOTIFIED[$jobid]=1
      continue
    fi
    status=$(flowrun::backend_job_status "$_FLOWRUN_JOB_ID" 2> /dev/null)
    case "$status" in
      COMPLETED|FAILED|CANCELLED)
        echo "[flowrun] Job $jobid ${status,,}" >&2
        _FLOWRUN_NOTIFIED[$jobid]=1
        ;;
      UNKNOWN) _FLOWRUN_NOTIFIED[$jobid]=1 ;;
    esac
  done < <(flowrun::session_jobs)
  return $rc
}

# --- Completion ------------------------------------------------------------------

# Flow version names: the named versions, then the executables in the search
# directories (no OPM check: completion must be fast)
flowrun::complete_versions() {
  local dir exe entry
  {
    for entry in "${FLOWRUN_FLOW_VERSIONS[@]}"; do
      echo "${entry%%=*}"
    done
    while IFS= read -r dir; do
      for exe in "$dir"/flow*; do
        [[ -f "$exe" && -x "$exe" ]] && echo "${exe##*/}"
      done
    done < <(flowrun::flow::search_dirs 2> /dev/null)
  } | sort -u
}

# Complete CUR as a value of KIND (see flowrun::directive_option and
# flowrun::directive_arguments), into COMPREPLY
flowrun::complete_kind() {
  local kind="$1" cur="$2" file
  case "$kind" in
    version) mapfile -t COMPREPLY < <(compgen -W "$(flowrun::complete_versions)" -- "$cur") ;;
    scheduler) mapfile -t COMPREPLY < <(compgen -W "auto lsf slurm pbs localq" -- "$cur") ;;
    job) mapfile -t COMPREPLY < <(compgen -W "$(flowrun::session_jobs)" -- "$cur") ;;
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

# Completion of the directives, flowrun::setup and flowrun. Directives compose
# (@submit -n 4 @mpi @flow ...): the nearest directive before the cursor
# decides. Job IDs contain ":", which bash treats as a word break, so the word
# being completed is taken from the command line itself.
flowrun::complete() {
  local line=${COMP_LINE:0:COMP_POINT} cur prev i context="" words=() options=""
  cur=${line##*[[:space:]]}
  read -ra words <<< "${line%"$cur"}"
  prev=${words[${#words[@]} - 1]:-}
  COMPREPLY=()

  for (( i = ${#words[@]} - 1; i >= 0; i-- )); do
    case "${words[i]}" in
      @*) context=${words[i]#@}; break ;;
      flowrun|*/flowrun|flowrun::setup) context=setup; break ;;
    esac
  done

  if [[ "$cur" == @* ]]; then
    mapfile -t COMPREPLY < <(compgen -A function -- "$cur")
    return 0
  fi

  # Options of the context and the kind of value each takes: declared by the
  # directives (flowrun::directive_option); for flowrun and flowrun::setup,
  # their options and the directive settings
  local -A kinds=()
  local spec kind description name
  if [[ "$context" == setup ]]; then
    for name in -n -q --lsf-options --slurm-options --pbs-options --localq-options; do
      kinds[$name]=text
    done
    for name in $(flowrun::directives_with_options); do
      kinds[--$name-options]=text
    done
    for name in "${!_FLOWRUN_SETTING_VAR[@]}"; do
      kinds[--$name]=${_FLOWRUN_SETTING_KIND[$name]:-text}
    done
    kinds[-s]=scheduler kinds[--scheduler]=scheduler kinds[--depends-on]=job kinds[--directives]=file
    options="${!kinds[*]} --dry-run"
    [[ "${words[0]}" == flowrun::setup ]] || options+=" -c --shell --jobs --jobs=all --library -h"
  elif [[ -n "$context" ]]; then
    while IFS=$'\t' read -r spec kind description; do
      [[ -n "$spec" ]] || continue
      for name in $(flowrun::option_names "$spec"); do
        options+=" $name"
        [[ "$kind" == - ]] || kinds[$name]=$kind
      done
    done <<< "${_FLOWRUN_DIRECTIVE_OPTION_LIST[$context]:-}"
  fi

  if [[ -n "${kinds[$prev]:-}" ]]; then
    flowrun::complete_kind "${kinds[$prev]}" "$cur"
  elif [[ "$cur" == -* && -n "$options" ]]; then
    mapfile -t COMPREPLY < <(compgen -W "$options" -- "$cur")
  elif [[ "$context" == setup ]]; then
    flowrun::complete_kind file "$cur"
  else
    flowrun::complete_kind "${_FLOWRUN_DIRECTIVE_ARGS[$context]:-file}" "$cur"
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
# flowrun::use loads more), flowrun::setup and flowrun
flowrun::register_completion() {
  local name
  for name in "${_FLOWRUN_DIRECTIVE_ORDER[@]}"; do
    complete -F flowrun::complete "@$name"
  done
  complete -F flowrun::complete flowrun::setup flowrun
}

# --- Startup ------------------------------------------------------------------------

flowrun::register_completion

# The marker goes first in the prompt, once (also if the library is sourced again)
if [[ "${PS1:-}" != *'$(flowrun::prompt)'* ]]; then
  PS1='$(flowrun::prompt)'"${PS1:-\$ }"
fi

# Notifications run last, keeping $? for the rest of the prompt
if [[ "$(declare -p PROMPT_COMMAND 2> /dev/null)" == "declare -a"* ]]; then
  [[ " ${PROMPT_COMMAND[*]} " == *" flowrun::notify "* ]] || PROMPT_COMMAND+=(flowrun::notify)
elif [[ "${PROMPT_COMMAND:-}" != *flowrun::notify* ]]; then
  PROMPT_COMMAND="${PROMPT_COMMAND:+$PROMPT_COMMAND; }flowrun::notify"
fi
