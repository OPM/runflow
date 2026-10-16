#!/usr/bin/env bash
# @wait - wait for jobs (core directive)

opmexec::directive wait "[JOBID...] | @directive ..." \
  "Wait for jobs (default: all jobs of this run), or for the jobs a directive submits"
opmexec::directive_arguments job

# Wait for jobs:
#   @wait ID...         the listed jobs
#   @wait               every job submitted in this run
#   @wait @directive... run the directive and wait for the job IDs it prints
#                       (lines SCHEDULER:ID; other output passes through), e.g.
#                       @wait @submit -n 8 @mpi @flow CASE.DATA
# Job IDs never start with "@", so a leading "@" means a command. Its IDs are
# passed through on stdout (job=$(@wait @submit ...) works); if it fails, its
# status is returned without waiting. Waits for every job; returns 1 if any of
# them did not complete successfully.
@wait() {
  opmexec::help_requested wait "$@" && return 0
  local jobid rc=0 output line
  local jobids=("$@")
  
  if [[ "${1:-}" == @* ]]; then
    output=$("$@") || return
    # Job IDs are the lines of the form SCHEDULER:ID (as @submit prints them);
    # all output is passed through
    jobids=()
    if [[ -n "$output" ]]; then
      while IFS= read -r line; do
        if [[ "$line" =~ ^([a-z]+):[^[:space:]]+$ ]] &&
           opmexec::validate_scheduler "${BASH_REMATCH[1]}" 2> /dev/null; then
          jobids+=("$line")
        fi
        printf '%s\n' "$line"
      done <<< "$output"
    fi
    if [[ ${#jobids[@]} -eq 0 ]]; then
      opmexec::error "@wait: $1 printed no job ID"
      return 1
    fi
  elif [[ $# -eq 0 ]]; then
    mapfile -t jobids < <(opmexec::session_jobs)
  fi
  
  for jobid in "${jobids[@]}"; do
    opmexec::wait_for_job "$jobid" || rc=1
  done
  
  return $rc
}

# Internal: Wait for a specific job
opmexec::wait_for_job() {
  local jobid="$1" status

  opmexec::parse_jobid "$jobid" || return 1
  jobid="$_OPMEXEC_JOB_SCHEDULER:$_OPMEXEC_JOB_ID"
  
  if opmexec::dry_run; then
    opmexec::dry "wait $jobid (assumed to complete successfully)"
    return 0
  fi
  
  opmexec::load_queue_backend "$_OPMEXEC_JOB_SCHEDULER" || return 1

  # No time limit unless OPMEXEC_WAIT_TIMEOUT (seconds, 0 = none) is set
  local timeout="${OPMEXEC_WAIT_TIMEOUT:-0}"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    opmexec::error "OPMEXEC_WAIT_TIMEOUT must be a number of seconds (got: $timeout)"
    return 1
  fi

  opmexec::debug "Waiting for job $jobid (timeout: ${timeout}s)..."

  # Backends that can block until a job ends do so; others are polled
  if declare -F opmexec::backend_wait_job > /dev/null; then
    status=$(opmexec::backend_wait_job "$_OPMEXEC_JOB_ID" "$timeout")
    [[ $? -eq 2 ]] && status=TIMEOUT
  else
    status=$(opmexec::poll_job_status "$_OPMEXEC_JOB_ID" "$timeout")
  fi

  case "$status" in
    COMPLETED)
      opmexec::mark_reported "$jobid"
      opmexec::info "Job $jobid completed successfully"
      return 0
      ;;
    FAILED|CANCELLED)
      opmexec::mark_reported "$jobid"
      opmexec::error "Job $jobid ${status,,}"
      ;;
    UNKNOWN)
      opmexec::mark_reported "$jobid"
      opmexec::error "Job $jobid not found"
      ;;
    TIMEOUT)
      opmexec::error "Job $jobid: gave up waiting after ${timeout}s (OPMEXEC_WAIT_TIMEOUT); the job keeps running"
      ;;
    *)
      opmexec::error "Job $jobid: cannot get status from $_OPMEXEC_JOB_SCHEDULER"
      ;;
  esac
  return 1
}

# Internal: Poll a job's status every OPMEXEC_POLL seconds until it is final.
# Prints the final status, TIMEOUT (after TIMEOUT seconds; 0 = never) or
# ERROR (after 5 failed status queries in a row; the backend's error is shown).
opmexec::poll_job_status() {
  local id="$1" timeout="$2" status failures=0 deadline=0
  (( timeout > 0 )) && deadline=$(( $(date +%s) + timeout ))

  while true; do
    status=$(opmexec::backend_job_status "$id" 2>/dev/null)

    case "$status" in
      COMPLETED|FAILED|CANCELLED|UNKNOWN)
        echo "$status"
        return 0
        ;;
      RUNNING|PENDING)
        failures=0
        ;;
      *)
        # No usable status: retry a few times (transient errors), then give up
        failures=$((failures + 1))
        if [[ $failures -ge 5 ]]; then
          opmexec::backend_job_status "$id" > /dev/null  # show the backend's error
          echo ERROR
          return 1
        fi
        ;;
    esac

    if (( deadline > 0 && $(date +%s) >= deadline )); then
      echo TIMEOUT
      return 2
    fi
    sleep "${OPMEXEC_POLL:-1}"
  done
}
