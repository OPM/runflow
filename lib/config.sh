#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Schedulers: which one to use, and loading its backend

source "$(dirname "${BASH_SOURCE[0]}")/common.sh" || return 1

# Known schedulers, and those whose backend is planned but not in this
# release: they are accepted for --dry-run (and their options are kept), but
# jobs cannot be submitted to them yet
_RUNFLOW_SCHEDULERS="localq lsf slurm pbs"
_RUNFLOW_PLANNED_SCHEDULERS="lsf slurm pbs"

# The scheduler of this machine: the first cluster scheduler whose commands
# are in PATH and whose backend exists, else the local queue (localq)
runflow::detect_scheduler() {
  local pair scheduler
  for pair in lsf:bsub slurm:sinfo pbs:qstat; do
    scheduler=${pair%%:*}
    command -v "${pair#*:}" > /dev/null || continue
    if [[ " $_RUNFLOW_PLANNED_SCHEDULERS " == *" $scheduler "* ]]; then
      runflow::debug "Found $scheduler (${pair#*:}), but its backend is planned: using localq"
      continue
    fi
    echo "$scheduler"
    return 0
  done
  echo localq
}

# The scheduler in use: runflow -s / RUNFLOW_SCHEDULER, or detected (auto)
runflow::get_scheduler() {
  if [[ "${RUNFLOW_SCHEDULER:-auto}" == auto ]]; then
    runflow::detect_scheduler
  else
    echo "$RUNFLOW_SCHEDULER"
  fi
}

# The default queue of a scheduler (RUNFLOW_DEFAULT_QUEUE_<SCHEDULER>)
runflow::get_default_queue() {
  runflow::validate_scheduler "$1" || return 1
  local var="RUNFLOW_DEFAULT_QUEUE_${1^^}"
  echo "${!var:-}"
}

# Load the backend of a scheduler, and check its tools
runflow::load_queue_backend() {
  local scheduler="$1"
  runflow::validate_scheduler "$scheduler" || return 1
  if [[ " $_RUNFLOW_PLANNED_SCHEDULERS " == *" $scheduler "* ]]; then
    runflow::error "The ${scheduler^^} backend is planned, not part of this release; --dry-run -s $scheduler shows the jobs a workflow would submit"
    return 1
  fi

  # Optional backend functions: drop those of a previously loaded backend
  unset -f runflow::backend_wait_job runflow::backend_check_requirements
  source "$(dirname "${BASH_SOURCE[0]}")/queue/$scheduler.sh" || return 1

  # Fail early, with an install hint, if the backend's tools are missing
  if declare -F runflow::backend_check_requirements > /dev/null; then
    runflow::backend_check_requirements || return 1
  fi
}

# Is SCHEDULER a known scheduler? An error if not.
runflow::validate_scheduler() {
  [[ " $_RUNFLOW_SCHEDULERS " == *" $1 "* ]] && return 0
  runflow::error "Unknown scheduler: $1 (known: ${_RUNFLOW_SCHEDULERS// /, }; ${_RUNFLOW_PLANNED_SCHEDULERS// /, }: planned)"
  return 1
}
