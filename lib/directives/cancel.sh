#!/usr/bin/env bash
# @cancel - cancel jobs (core directive)

flowrun::directive cancel "[JOBID...] | --all" "Cancel jobs (--all, or no IDs in a script: all active jobs of this run)"
flowrun::directive_option "--all" - "Cancel every pending and running job of this run"
flowrun::directive_arguments job

# Cancel job(s); --all (or no args, except in interactive shells): cancel this
# session's pending/running jobs
@cancel() {
  local jobid status rc=0 all=false
  local jobids=("$@")
  
  if [[ "${1:-}" == -* && "$1" != --all ]]; then
    flowrun::unknown_option cancel "$1"
    return 1
  elif [[ "${1:-}" == --all ]]; then
    all=true
    shift
    jobids=("$@")
  elif [[ $# -eq 0 ]]; then
    if [[ -n "${_FLOWRUN_INTERACTIVE:-}" ]]; then
      flowrun::error "@cancel: name the jobs to cancel, or use @cancel --all for every job of this shell (Tab lists them)"
      return 1
    fi
    all=true
  fi
  if $all; then
    if [[ $# -gt 0 ]]; then
      flowrun::error "@cancel: --all takes no job IDs"
      return 1
    fi
    mapfile -t jobids < <(flowrun::session_jobs)
  fi
  
  for jobid in "${jobids[@]}"; do
    flowrun::parse_jobid "$jobid" || { rc=1; continue; }
    jobid="$_FLOWRUN_JOB_SCHEDULER:$_FLOWRUN_JOB_ID"
    
    if flowrun::dry_run; then
      flowrun::dry "cancel $jobid"
      continue
    fi
    
    flowrun::load_queue_backend "$_FLOWRUN_JOB_SCHEDULER" || { rc=1; continue; }
    
    # Session jobs: skip the ones that already finished
    if $all; then
      status=$(flowrun::backend_job_status "$_FLOWRUN_JOB_ID" 2>/dev/null)
      [[ "$status" == PENDING || "$status" == RUNNING ]] || continue
    fi
    
    if flowrun::backend_cancel_job "$_FLOWRUN_JOB_ID"; then
      flowrun::info "Job $jobid cancelled"
      flowrun::mark_reported "$jobid"
    else
      rc=1
    fi
  done
  
  return $rc
}
