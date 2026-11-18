#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @wait - wait for jobs (core directive)

flowrun::directive wait "[JOBID...] | @directive ..." \
  "Wait for jobs (default: all jobs of this run), or for the jobs a directive submits"
flowrun::directive_arguments job

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
    flowrun::unknown_option wait "$1"
    return 1
  elif [[ "${1:-}" == @* ]]; then
    output=$("$@") || return
    # Job IDs are the lines of the form SCHEDULER:ID (as @submit prints them);
    # all output is passed through
    jobids=()
    if [[ -n "$output" ]]; then
      while IFS= read -r line; do
        if [[ "$line" =~ ^([a-z]+):[^[:space:]]+$ ]] &&
           flowrun::validate_scheduler "${BASH_REMATCH[1]}" 2> /dev/null; then
          jobids+=("$line")
        fi
        printf '%s\n' "$line"
      done <<< "$output"
    fi
    if [[ ${#jobids[@]} -eq 0 ]]; then
      flowrun::error "@wait: $1 printed no job ID"
      return 1
    fi
  elif [[ $# -eq 0 ]]; then
    mapfile -t jobids < <(flowrun::session_jobs)
  fi
  
  for jobid in "${jobids[@]}"; do
    flowrun::wait_for_job "$jobid" || rc=1
  done
  
  return $rc
}

# Internal: Wait for a specific job
flowrun::wait_for_job() {
  local jobid="$1" status

  flowrun::parse_jobid "$jobid" || return 1
  jobid="$_FLOWRUN_JOB_SCHEDULER:$_FLOWRUN_JOB_ID"
  
  if flowrun::dry_run; then
    flowrun::dry "wait $jobid (assumed to complete successfully)"
    return 0
  fi
  
  flowrun::load_queue_backend "$_FLOWRUN_JOB_SCHEDULER" || return 1

  # No time limit unless FLOWRUN_WAIT_TIMEOUT (seconds, 0 = none) is set
  local timeout="${FLOWRUN_WAIT_TIMEOUT:-0}"
  if ! [[ "$timeout" =~ ^[0-9]+$ ]]; then
    flowrun::error "FLOWRUN_WAIT_TIMEOUT must be a number of seconds (got: $timeout)"
    return 1
  fi

  flowrun::debug "Waiting for job $jobid (timeout: ${timeout}s)..."

  # Backends that can block until a job ends do so; others are polled
  if declare -F flowrun::backend_wait_job > /dev/null; then
    status=$(flowrun::backend_wait_job "$_FLOWRUN_JOB_ID" "$timeout")
    [[ $? -eq 2 ]] && status=TIMEOUT
  else
    status=$(flowrun::poll_job_status "$_FLOWRUN_JOB_ID" "$timeout")
  fi

  case "$status" in
    COMPLETED)
      flowrun::mark_reported "$jobid"
      flowrun::info "Job $jobid completed successfully"
      return 0
      ;;
    FAILED|CANCELLED)
      flowrun::mark_reported "$jobid"
      flowrun::error "Job $jobid ${status,,}"
      ;;
    UNKNOWN)
      flowrun::mark_reported "$jobid"
      flowrun::error "Job $jobid not found"
      ;;
    TIMEOUT)
      flowrun::error "Job $jobid: gave up waiting after ${timeout}s (FLOWRUN_WAIT_TIMEOUT); the job keeps running"
      ;;
    *)
      flowrun::error "Job $jobid: cannot get status from $_FLOWRUN_JOB_SCHEDULER"
      ;;
  esac
  return 1
}

# Internal: Poll a job's status every FLOWRUN_POLL seconds until it is final.
# Prints the final status, TIMEOUT (after TIMEOUT seconds; 0 = never) or
# ERROR (after 5 failed status queries in a row; the backend's error is shown).
flowrun::poll_job_status() {
  local id="$1" timeout="$2" status failures=0 deadline=0
  (( timeout > 0 )) && deadline=$(( $(date +%s) + timeout ))

  while true; do
    status=$(flowrun::backend_job_status "$id" 2>/dev/null)

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
          flowrun::backend_job_status "$id" > /dev/null  # show the backend's error
          echo ERROR
          return 1
        fi
        ;;
    esac

    if (( deadline > 0 && $(date +%s) >= deadline )); then
      echo TIMEOUT
      return 2
    fi
    sleep "${FLOWRUN_POLL:-1}"
  done
}
