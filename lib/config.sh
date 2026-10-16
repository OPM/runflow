#!/usr/bin/env bash
# Schedulers: which one to use, and loading its backend

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" || return 1

# Known schedulers, and those whose backend is planned but not in this
# release: they are accepted for --dry-run (and their options are kept), but
# jobs cannot be submitted to them yet
_OPMEXEC_SCHEDULERS="localq lsf slurm pbs"
_OPMEXEC_PLANNED_SCHEDULERS="lsf slurm pbs"

# The scheduler of this machine: the first cluster scheduler whose commands
# are in PATH and whose backend exists, else the local queue (localq)
opmexec::detect_scheduler() {
  local pair scheduler
  for pair in lsf:bsub slurm:sinfo pbs:qstat; do
    scheduler=${pair%%:*}
    command -v "${pair#*:}" > /dev/null || continue
    if [[ " $_OPMEXEC_PLANNED_SCHEDULERS " == *" $scheduler "* ]]; then
      opmexec::debug "Found $scheduler (${pair#*:}), but its backend is planned: using localq"
      continue
    fi
    echo "$scheduler"
    return 0
  done
  echo localq
}

# The scheduler in use: opmexec -s / OPMEXEC_SCHEDULER, or detected (auto)
opmexec::get_scheduler() {
  if [[ "${OPMEXEC_SCHEDULER:-auto}" == auto ]]; then
    opmexec::detect_scheduler
  else
    echo "$OPMEXEC_SCHEDULER"
  fi
}

# The default queue of a scheduler (OPMEXEC_DEFAULT_QUEUE_<SCHEDULER>)
opmexec::get_default_queue() {
  opmexec::validate_scheduler "$1" || return 1
  local var="OPMEXEC_DEFAULT_QUEUE_${1^^}"
  echo "${!var:-}"
}

# Load the backend of a scheduler, and check its tools
opmexec::load_queue_backend() {
  local scheduler="$1"
  opmexec::validate_scheduler "$scheduler" || return 1
  if [[ " $_OPMEXEC_PLANNED_SCHEDULERS " == *" $scheduler "* ]]; then
    opmexec::error "The ${scheduler^^} backend is planned, not part of this release; --dry-run -s $scheduler shows the jobs a workflow would submit"
    return 1
  fi

  # Optional backend functions: drop those of a previously loaded backend
  unset -f opmexec::backend_wait_job opmexec::backend_check_requirements
  source "$(dirname "${BASH_SOURCE[0]}")/queue/$scheduler.sh" || return 1

  # Fail early, with an install hint, if the backend's tools are missing
  if declare -F opmexec::backend_check_requirements > /dev/null; then
    opmexec::backend_check_requirements || return 1
  fi
}

# Is SCHEDULER a known scheduler? An error if not.
opmexec::validate_scheduler() {
  [[ " $_OPMEXEC_SCHEDULERS " == *" $1 "* ]] && return 0
  opmexec::error "Unknown scheduler: $1 (known: ${_OPMEXEC_SCHEDULERS// /, }; ${_OPMEXEC_PLANNED_SCHEDULERS// /, }: planned)"
  return 1
}
