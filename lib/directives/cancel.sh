#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @cancel - cancel jobs (core directive)

runflow::directive cancel "[JOBID...] | --all" "Cancel jobs (--all, or no IDs in a script: all active jobs of this run)"
runflow::directive_option "--all" - "Cancel every pending and running job of this run"
runflow::directive_arguments job

# Cancel job(s); --all (or no args, except in interactive shells): cancel this
# session's pending/running jobs
@cancel() {
  local jobid status rc=0 all=false
  local jobids=("$@")
  
  if [[ "${1:-}" == -* && "$1" != --all ]]; then
    runflow::unknown_option cancel "$1"
    return 1
  elif [[ "${1:-}" == --all ]]; then
    all=true
    shift
    jobids=("$@")
  elif [[ $# -eq 0 ]]; then
    if [[ -n "${_RUNFLOW_INTERACTIVE:-}" ]]; then
      runflow::error "@cancel: name the jobs to cancel, or use @cancel --all for every job of this shell (Tab lists them)"
      return 1
    fi
    all=true
  fi
  if $all; then
    if [[ $# -gt 0 ]]; then
      runflow::error "@cancel: --all takes no job IDs"
      return 1
    fi
    mapfile -t jobids < <(runflow::session_jobs)
  fi
  
  for jobid in "${jobids[@]}"; do
    runflow::parse_jobid "$jobid" || { rc=1; continue; }
    jobid="$_RUNFLOW_JOB_SCHEDULER:$_RUNFLOW_JOB_ID"
    
    if runflow::dry_run; then
      runflow::dry "cancel $jobid"
      continue
    fi
    
    runflow::load_queue_backend "$_RUNFLOW_JOB_SCHEDULER" || { rc=1; continue; }
    
    # Session jobs: skip the ones that already finished
    if $all; then
      status=$(runflow::backend_job_status "$_RUNFLOW_JOB_ID" 2>/dev/null)
      [[ "$status" == PENDING || "$status" == RUNNING ]] || continue
    fi
    
    if runflow::backend_cancel_job "$_RUNFLOW_JOB_ID"; then
      runflow::info "Job $jobid cancelled"
      runflow::mark_reported "$jobid"
    else
      rc=1
    fi
  done
  
  return $rc
}
