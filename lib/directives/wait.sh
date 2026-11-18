#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @wait - wait for jobs (core directive)

runflow::directive wait "[JOBID...] | @directive ..." \
  "Wait for jobs (default: all jobs of this run), or for the jobs a directive submits"
runflow::directive_arguments job

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
  local jobid rc=0 output line
  local jobids=("$@")

  if [[ "${1:-}" == -* ]]; then
    runflow::unknown_option wait "$1"
    return 1
  elif [[ "${1:-}" == @* ]]; then
    output=$("$@") || return
    # Job IDs are the lines of the form SCHEDULER:ID (as @submit prints them);
    # all output is passed through
    jobids=()
    if [[ -n "$output" ]]; then
      while IFS= read -r line; do
        if [[ "$line" =~ ^([a-z]+):[^[:space:]]+$ ]] &&
           runflow::validate_scheduler "${BASH_REMATCH[1]}" 2> /dev/null; then
          jobids+=("$line")
        fi
        printf '%s\n' "$line"
      done <<< "$output"
    fi
    if [[ ${#jobids[@]} -eq 0 ]]; then
      runflow::error "@wait: $1 printed no job ID"
      return 1
    fi
  elif [[ $# -eq 0 ]]; then
    mapfile -t jobids < <(runflow::session_jobs)
  fi
  
  for jobid in "${jobids[@]}"; do
    runflow::wait_for_job "$jobid" || rc=1
  done
  
  return $rc
}

# Internal: Wait for a specific job
runflow::wait_for_job() {
  local jobid="$1" status

  runflow::parse_jobid "$jobid" || return 1
  jobid="$_RUNFLOW_JOB_SCHEDULER:$_RUNFLOW_JOB_ID"
  
  if runflow::dry_run; then
    runflow::dry "wait $jobid (assumed to complete successfully)"
    return 0
  fi
  
  runflow::load_queue_backend "$_RUNFLOW_JOB_SCHEDULER" || return 1

  # No time limit unless RUNFLOW_WAIT_TIMEOUT (seconds, 0 = none) is set
  local timeout="${RUNFLOW_WAIT_TIMEOUT:-0}"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    runflow::error "RUNFLOW_WAIT_TIMEOUT must be a number of seconds (got: $timeout)"
    return 1
  fi

  runflow::debug "Waiting for job $jobid (timeout: ${timeout}s)..."

  # Backends that can block until a job ends do so; others are polled
  if declare -F runflow::backend_wait_job > /dev/null; then
    status=$(runflow::backend_wait_job "$_RUNFLOW_JOB_ID" "$timeout")
    [[ $? -eq 2 ]] && status=TIMEOUT
  else
    status=$(runflow::poll_job_status "$_RUNFLOW_JOB_ID" "$timeout")
  fi

  case "$status" in
    COMPLETED)
      runflow::mark_reported "$jobid"
      runflow::info "Job $jobid completed successfully"
      return 0
      ;;
    FAILED|CANCELLED)
      runflow::mark_reported "$jobid"
      runflow::error "Job $jobid ${status,,}"
      ;;
    UNKNOWN)
      runflow::mark_reported "$jobid"
      runflow::error "Job $jobid not found"
      ;;
    TIMEOUT)
      runflow::error "Job $jobid: gave up waiting after ${timeout}s (RUNFLOW_WAIT_TIMEOUT); the job keeps running"
      ;;
    *)
      runflow::error "Job $jobid: cannot get status from $_RUNFLOW_JOB_SCHEDULER"
      ;;
  esac
  return 1
}

# Internal: Poll a job's status every RUNFLOW_POLL seconds until it is final.
# Prints the final status, TIMEOUT (after TIMEOUT seconds; 0 = never) or
# ERROR (after 5 failed status queries in a row; the backend's error is shown).
runflow::poll_job_status() {
  local id="$1" timeout="$2" status failures=0 deadline=0
  (( timeout > 0 )) && deadline=$(( $(date +%s) + timeout ))

  while true; do
    status=$(runflow::backend_job_status "$id" 2>/dev/null)

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
          runflow::backend_job_status "$id" > /dev/null  # show the backend's error
          echo ERROR
          return 1
        fi
        ;;
    esac

    if (( deadline > 0 && $(date +%s) >= deadline )); then
      echo TIMEOUT
      return 2
    fi
    sleep "${RUNFLOW_POLL:-1}"
  done
}
