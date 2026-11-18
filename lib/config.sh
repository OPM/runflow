#!/usr/bin/env bash
# Schedulers: which one to use, and loading its backend

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" || return 1

# Known schedulers, and those whose backend is planned but not in this
# release: they are accepted for --dry-run (and their options are kept), but
# jobs cannot be submitted to them yet
_FLOWRUN_SCHEDULERS="localq lsf slurm pbs"
_FLOWRUN_PLANNED_SCHEDULERS="lsf slurm pbs"

# The scheduler of this machine: the first cluster scheduler whose commands
# are in PATH and whose backend exists, else the local queue (localq)
flowrun::detect_scheduler() {
  local pair scheduler
  for pair in lsf:bsub slurm:sinfo pbs:qstat; do
    scheduler=${pair%%:*}
    command -v "${pair#*:}" > /dev/null || continue
    if [[ " $_FLOWRUN_PLANNED_SCHEDULERS " == *" $scheduler "* ]]; then
      flowrun::debug "Found $scheduler (${pair#*:}), but its backend is planned: using localq"
      continue
    fi
    echo "$scheduler"
    return 0
  done
  echo localq
}

# The scheduler in use: flowrun -s / FLOWRUN_SCHEDULER, or detected (auto)
flowrun::get_scheduler() {
  if [[ "${FLOWRUN_SCHEDULER:-auto}" == auto ]]; then
    flowrun::detect_scheduler
  else
    echo "$FLOWRUN_SCHEDULER"
  fi
}

# The default queue of a scheduler (FLOWRUN_DEFAULT_QUEUE_<SCHEDULER>)
flowrun::get_default_queue() {
  flowrun::validate_scheduler "$1" || return 1
  local var="FLOWRUN_DEFAULT_QUEUE_${1^^}"
  echo "${!var:-}"
}

# Load the backend of a scheduler, and check its tools
flowrun::load_queue_backend() {
  local scheduler="$1"
  flowrun::validate_scheduler "$scheduler" || return 1
  if [[ " $_FLOWRUN_PLANNED_SCHEDULERS " == *" $scheduler "* ]]; then
    flowrun::error "The ${scheduler^^} backend is planned, not part of this release; --dry-run -s $scheduler shows the jobs a workflow would submit"
    return 1
  fi

  # Optional backend functions: drop those of a previously loaded backend
  unset -f flowrun::backend_wait_job flowrun::backend_check_requirements
  source "$(dirname "${BASH_SOURCE[0]}")/queue/$scheduler.sh" || return 1

  # Fail early, with an install hint, if the backend's tools are missing
  if declare -F flowrun::backend_check_requirements > /dev/null; then
    flowrun::backend_check_requirements || return 1
  fi
}

# Is SCHEDULER a known scheduler? An error if not.
flowrun::validate_scheduler() {
  [[ " $_FLOWRUN_SCHEDULERS " == *" $1 "* ]] && return 0
  flowrun::error "Unknown scheduler: $1 (known: ${_FLOWRUN_SCHEDULERS// /, }; ${_FLOWRUN_PLANNED_SCHEDULERS// /, }: planned)"
  return 1
}
