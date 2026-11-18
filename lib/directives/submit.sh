#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @submit - queue a command or directive (core directive)

runflow::directive submit \
  "[-n NP] [-q QUEUE] [--scheduler S] [--depends-on ID,...] [--<scheduler>-options OPTS] [-o OUTPUT] command|directive ..." \
  "Queue a job and print its ID (to wait for it: @wait @submit ...)"
runflow::directive_option "-n, --np NP" text "Number of tasks to reserve (default: runflow -n, else 1)"
runflow::directive_option "-q, --queue QUEUE" text "Queue or partition (default: runflow -q, else the configured one)"
runflow::directive_option "--scheduler S" scheduler "auto, lsf, slurm, pbs or localq (default: runflow -s)"
runflow::directive_option "--depends-on ID[,ID...]" job "Start after these jobs completed (repeatable)"
runflow::directive_option "--lsf-options, --slurm-options, --pbs-options, --localq-options OPTS" text \
  "Native options, used only when the job goes to that scheduler"
runflow::directive_option "-o, --output FILE" file "File for the job's output (default: a per-job log)"
runflow::directive_option "--" - "End of @submit's options (before a command that starts with -)"
runflow::directive_arguments command

# Submit a job (non-blocking, prints the qualified job ID, e.g. localq:12);
# to wait for it as well: @wait @submit ...
@submit() {
  runflow::ensure_state_dirs
  
  local scheduler command np queue depends_on output_file name
  local -A scheduler_options=()
  
  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--np) runflow::has_value @submit "$@" || return 1; np="$2"; shift 2 ;;
      -q|--queue) runflow::has_value @submit "$@" || return 1; queue="$2"; shift 2 ;;
      --scheduler) runflow::has_value @submit "$@" || return 1; scheduler="$2"; shift 2 ;;
      --depends-on)
        # Repeatable; accumulates a comma-separated list. Reject an empty value
        # (e.g. from a failed job=$(@submit ...)) rather than silently drop it.
        if [[ -z "${2//[ ,]/}" ]]; then
          runflow::error "@submit: --depends-on needs a job ID (got: '$2')"
          return 1
        fi
        depends_on="${depends_on:+$depends_on,}$2"
        shift 2
        ;;
      --*-options)
        # --<scheduler>-options: only used when the job goes to that scheduler
        runflow::has_value @submit "$@" || return 1
        name=$(runflow::options_scheduler "$1") || return 1
        scheduler_options[$name]="${scheduler_options[$name]:+${scheduler_options[$name]} }$2"
        shift 2
        ;;
      -o|--output) runflow::has_value @submit "$@" || return 1; output_file="$2"; shift 2 ;;
      --) shift; break ;;
      -*)
        runflow::unknown_option submit "$1" "use -- before a command that starts with -"
        return 1
        ;;
      *) break ;;
    esac
  done
  
  # Remaining args are the command to submit
  command=("$@")
  
  if [[ ${#command[@]} -eq 0 ]]; then
    runflow::error "No command specified for @submit"
    return 1
  fi
  
  # Use runflow defaults if not specified; the workflow's dependencies
  # (runflow --depends-on) and the call's add up
  np=${np:-${RUNFLOW_NP:-1}}
  if ! [[ "$np" =~ ^[1-9][0-9]*$ ]]; then
    runflow::error "@submit: number of processes must be a positive integer (got: $np)"
    return 1
  fi
  queue=${queue:-${RUNFLOW_QUEUE:-}}
  depends_on=${RUNFLOW_DEPENDS_ON:-}${RUNFLOW_DEPENDS_ON:+${depends_on:+,}}${depends_on:-}
  [[ "$scheduler" == "auto" ]] && scheduler=""
  scheduler=${scheduler:-$(runflow::get_scheduler)} || return 1
  
  # Dependencies must be in the same scheduler; pass bare IDs to the
  # backend. Also normalizes the list: "3, 4,,5" -> "3,4,5"
  local dep deps=()
  for dep in ${depends_on//,/ }; do
    runflow::parse_jobid "$dep" "$scheduler" || return 1
    if [[ "$_RUNFLOW_JOB_SCHEDULER" != "$scheduler" ]]; then
      runflow::error "@submit: job $dep cannot be a dependency of a job submitted to $scheduler.
        Dependencies must be in the same scheduler. Wait for it first instead:
          @wait $dep && @submit --scheduler $scheduler ..."
      return 1
    fi
    [[ ",${deps[*]}," == *",$_RUNFLOW_JOB_ID,"* ]] || deps+=("$_RUNFLOW_JOB_ID")
  done
  depends_on=$(IFS=,; echo "${deps[*]}")
  # Empty queue: the scheduler's default; empty output_file: the backend
  # picks a per-job log in $RUNFLOW_LOG_DIR
  queue=${queue:-$(runflow::get_default_queue "$scheduler")} || return 1
  
  # Native options for this scheduler: site and workflow defaults
  # (RUNFLOW_<SCHEDULER>_OPTIONS), then this call's --<scheduler>-options
  local options_var="RUNFLOW_${scheduler^^}_OPTIONS" options
  options="${!options_var:-}"
  options="${options:+$options }${scheduler_options[$scheduler]:-}"
  runflow::split_options "$options" "--$scheduler-options" || return 1
  
  local jobid
  
  if runflow::dry_run; then
    jobid="$scheduler:dry$(( $(runflow::session_jobs | wc -l) + 1 ))"
    echo "$jobid" >> "$RUNFLOW_SESSION_FILE" 2>/dev/null || true
    runflow::dry "submit $jobid: queue=${queue:-default} np=$np${depends_on:+ depends_on=$depends_on}${output_file:+ output=$output_file}${options:+ options=$options}"
    runflow::dry "  command: $(runflow::quoted "${command[@]}")"
    
    # Check the directive the job would run, as it would run inside the job
    if [[ "${command[0]}" == @* ]]; then
      ( export RUNFLOW_NP="$np" RUNFLOW_JOB_SCHEDULER="$scheduler"; "${command[@]}" ) 2>&1 | sed 's/^/    /' >&2
      if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        runflow::dry "  warning: ${command[0]} would fail inside job $jobid"
      fi
    fi
    
    echo "$jobid"
    return 0
  fi
  
  # Directives (e.g. @mpi @flow) run inside the job allocation via runflow
  if [[ "${command[0]}" == @* ]]; then
    command=("$RUNFLOW_HOME/runflow" -n "$np" -c "${command[@]}")
  fi
  
  # The job's environment: the scheduler it runs under (selects the @mpi
  # launcher), its process count (the default of @mpi and of any runflow
  # inside the job, also in scripts) and the workflow's settings, passed
  # explicitly so that jobs behave the same whether or not the site passes
  # the environment on
  local job_env=("RUNFLOW_JOB_SCHEDULER=$scheduler" "RUNFLOW_NP=$np") var
  for var in $(runflow::job_variables); do
    [[ -v $var ]] && job_env+=("$var=${!var}")
  done
  
  # Run the job in the submission directory, after the site's job setup
  # (RUNFLOW_JOB_SETUP, e.g. module loads; the job fails if it fails). This is
  # a portable "env -C DIR --" (BSD env has no -C); "env --" lets a command
  # start with "-". One line: job listings strip it from the saved command.
  command=(bash -c 'cd "$1" || exit; setup=$2; shift 2; if [ -n "$setup" ]; then eval "$setup" || { echo "runflow: job setup failed: $setup" >&2; exit 1; }; fi; exec env -- "$@"'
           runflow-job "$PWD" "${RUNFLOW_JOB_SETUP:-}" "${job_env[@]}" "${command[@]}")
  
  runflow::debug "@submit: scheduler=$scheduler, queue=$queue, np=$np, options=$options, cmd=${command[*]}"
  
  # Load backend and submit
  runflow::load_queue_backend "$scheduler" || return 1
  
  jobid=$(runflow::backend_submit_job "$queue" "$np" "$output_file" "$depends_on" "$options" "${command[@]}") || return 1
  jobid="$scheduler:$jobid"
  
  # Track job
  echo "$jobid" >> "$RUNFLOW_SESSION_FILE" 2>/dev/null || true
  
  runflow::debug "@submit: submitted job $jobid"
  echo "$jobid"
  return 0
}
