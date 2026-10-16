#!/usr/bin/env bash
# @cancel - cancel jobs (core directive)

opmexec::directive cancel "[JOBID...] | --all" "Cancel jobs (--all, or no IDs in a script: all active jobs of this run)"
opmexec::directive_option "--all" - "Cancel every pending and running job of this run"
opmexec::directive_arguments job

# Cancel job(s); --all (or no args, except in interactive shells): cancel this
# session's pending/running jobs
@cancel() {
  opmexec::help_requested cancel "$@" && return 0
  local jobid status rc=0 all=false
  local jobids=("$@")
  
  if [[ "${1:-}" == --all ]]; then
    all=true
    shift
    jobids=("$@")
  elif [[ $# -eq 0 ]]; then
    if [[ -n "${_OPMEXEC_INTERACTIVE:-}" ]]; then
      opmexec::error "@cancel: name the jobs to cancel, or use @cancel --all for every job of this shell (Tab lists them)"
      return 1
    fi
    all=true
  fi
  if $all; then
    if [[ $# -gt 0 ]]; then
      opmexec::error "@cancel: --all takes no job IDs"
      return 1
    fi
    mapfile -t jobids < <(opmexec::session_jobs)
  fi
  
  for jobid in "${jobids[@]}"; do
    opmexec::parse_jobid "$jobid" || { rc=1; continue; }
    jobid="$_OPMEXEC_JOB_SCHEDULER:$_OPMEXEC_JOB_ID"
    
    if opmexec::dry_run; then
      opmexec::dry "cancel $jobid"
      continue
    fi
    
    opmexec::load_queue_backend "$_OPMEXEC_JOB_SCHEDULER" || { rc=1; continue; }
    
    # Session jobs: skip the ones that already finished
    if $all; then
      status=$(opmexec::backend_job_status "$_OPMEXEC_JOB_ID" 2>/dev/null)
      [[ "$status" == PENDING || "$status" == RUNNING ]] || continue
    fi
    
    if opmexec::backend_cancel_job "$_OPMEXEC_JOB_ID"; then
      opmexec::info "Job $jobid cancelled"
      opmexec::mark_reported "$jobid"
    else
      rc=1
    fi
  done
  
  return $rc
}
