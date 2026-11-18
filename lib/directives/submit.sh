#!/usr/bin/env bash
# @submit - queue a command or directive (core directive)

flowrun::directive submit \
  "[-n NP] [-q QUEUE] [--scheduler S] [--depends-on ID,...] [--<scheduler>-options OPTS] [-o OUTPUT] command|directive ..." \
  "Queue a job and print its ID (to wait for it: @wait @submit ...)"
flowrun::directive_option "-n, --np NP" text "Number of tasks to reserve (default: flowrun -n, else 1)"
flowrun::directive_option "-q, --queue QUEUE" text "Queue or partition (default: flowrun -q, else the configured one)"
flowrun::directive_option "--scheduler S" scheduler "auto, lsf, slurm, pbs or localq (default: flowrun -s)"
flowrun::directive_option "--depends-on ID[,ID...]" job "Start after these jobs completed (repeatable)"
flowrun::directive_option "--lsf-options, --slurm-options, --pbs-options, --localq-options OPTS" text \
  "Native options, used only when the job goes to that scheduler"
flowrun::directive_option "-o, --output FILE" file "File for the job's output (default: a per-job log)"
flowrun::directive_option "--" - "End of @submit's options (before a command that starts with -)"
flowrun::directive_arguments command

# Submit a job (non-blocking, prints the qualified job ID, e.g. localq:12);
# to wait for it as well: @wait @submit ...
@submit() {
  flowrun::ensure_state_dirs
  
  local scheduler command np queue depends_on output_file name
  local -A scheduler_options=()
  
  # Parse options
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -n|--np) flowrun::has_value @submit "$@" || return 1; np="$2"; shift 2 ;;
      -q|--queue) flowrun::has_value @submit "$@" || return 1; queue="$2"; shift 2 ;;
      --scheduler) flowrun::has_value @submit "$@" || return 1; scheduler="$2"; shift 2 ;;
      --depends-on)
        # Repeatable; accumulates a comma-separated list. Reject an empty value
        # (e.g. from a failed job=$(@submit ...)) rather than silently drop it.
        if [[ -z "${2//[ ,]/}" ]]; then
          flowrun::error "@submit: --depends-on needs a job ID (got: '$2')"
          return 1
        fi
        depends_on="${depends_on:+$depends_on,}$2"
        shift 2
        ;;
      --*-options)
        # --<scheduler>-options: only used when the job goes to that scheduler
        flowrun::has_value @submit "$@" || return 1
        name=$(flowrun::options_scheduler "$1") || return 1
        scheduler_options[$name]="${scheduler_options[$name]:+${scheduler_options[$name]} }$2"
        shift 2
        ;;
      -o|--output) flowrun::has_value @submit "$@" || return 1; output_file="$2"; shift 2 ;;
      --) shift; break ;;
      -*)
        flowrun::unknown_option submit "$1" "use -- before a command that starts with -"
        return 1
        ;;
      *) break ;;
    esac
  done
  
  # Remaining args are the command to submit
  command=("$@")
  
  if [[ ${#command[@]} -eq 0 ]]; then
    flowrun::error "No command specified for @submit"
    return 1
  fi
  
  # Use flowrun defaults if not specified; the workflow's dependencies
  # (flowrun --depends-on) and the call's add up
  np=${np:-${FLOWRUN_NP:-1}}
  if ! [[ "$np" =~ ^[1-9][0-9]*$ ]]; then
    flowrun::error "@submit: number of processes must be a positive integer (got: $np)"
    return 1
  fi
  queue=${queue:-${FLOWRUN_QUEUE:-}}
  depends_on=${FLOWRUN_DEPENDS_ON:-}${FLOWRUN_DEPENDS_ON:+${depends_on:+,}}${depends_on:-}
  [[ "$scheduler" == "auto" ]] && scheduler=""
  scheduler=${scheduler:-$(flowrun::get_scheduler)} || return 1
  
  # Dependencies must be in the same scheduler; pass bare IDs to the
  # backend. Also normalizes the list: "3, 4,,5" -> "3,4,5"
  local dep deps=()
  for dep in ${depends_on//,/ }; do
    flowrun::parse_jobid "$dep" "$scheduler" || return 1
    if [[ "$_FLOWRUN_JOB_SCHEDULER" != "$scheduler" ]]; then
      flowrun::error "@submit: job $dep cannot be a dependency of a job submitted to $scheduler.
        Dependencies must be in the same scheduler. Wait for it first instead:
          @wait $dep && @submit --scheduler $scheduler ..."
      return 1
    fi
    [[ ",${deps[*]}," == *",$_FLOWRUN_JOB_ID,"* ]] || deps+=("$_FLOWRUN_JOB_ID")
  done
  depends_on=$(IFS=,; echo "${deps[*]}")
  # Empty queue: the scheduler's default; empty output_file: the backend
  # picks a per-job log in $FLOWRUN_LOG_DIR
  queue=${queue:-$(flowrun::get_default_queue "$scheduler")} || return 1
  
  # Native options for this scheduler: site and workflow defaults
  # (FLOWRUN_<SCHEDULER>_OPTIONS), then this call's --<scheduler>-options
  local options_var="FLOWRUN_${scheduler^^}_OPTIONS" options
  options="${!options_var:-}"
  options="${options:+$options }${scheduler_options[$scheduler]:-}"
  flowrun::split_options "$options" "--$scheduler-options" || return 1
  
  local jobid
  
  if flowrun::dry_run; then
    jobid="$scheduler:dry$(( $(flowrun::session_jobs | wc -l) + 1 ))"
    echo "$jobid" >> "$FLOWRUN_SESSION_FILE" 2>/dev/null || true
    flowrun::dry "submit $jobid: queue=${queue:-default} np=$np${depends_on:+ depends_on=$depends_on}${output_file:+ output=$output_file}${options:+ options=$options}"
    flowrun::dry "  command: $(flowrun::quoted "${command[@]}")"
    
    # Check the directive the job would run, as it would run inside the job
    if [[ "${command[0]}" == @* ]]; then
      ( export FLOWRUN_NP="$np" FLOWRUN_JOB_SCHEDULER="$scheduler"; "${command[@]}" ) 2>&1 | sed 's/^/    /' >&2
      if [[ "${PIPESTATUS[0]}" -ne 0 ]]; then
        flowrun::dry "  warning: ${command[0]} would fail inside job $jobid"
      fi
    fi
    
    echo "$jobid"
    return 0
  fi
  
  # Directives (e.g. @mpi @flow) run inside the job allocation via flowrun
  if [[ "${command[0]}" == @* ]]; then
    command=("$FLOWRUN_HOME/flowrun" -n "$np" -c "${command[@]}")
  fi
  
  # The job's environment: the scheduler it runs under (selects the @mpi
  # launcher), its process count (the default of @mpi and of any flowrun
  # inside the job, also in scripts) and the workflow's settings, passed
  # explicitly so that jobs behave the same whether or not the site passes
  # the environment on
  local job_env=("FLOWRUN_JOB_SCHEDULER=$scheduler" "FLOWRUN_NP=$np") var
  for var in $(flowrun::job_variables); do
    [[ -v $var ]] && job_env+=("$var=${!var}")
  done
  
  # Run the job in the submission directory, after the site's job setup
  # (FLOWRUN_JOB_SETUP, e.g. module loads; the job fails if it fails). This is
  # a portable "env -C DIR --" (BSD env has no -C); "env --" lets a command
  # start with "-". One line: job listings strip it from the saved command.
  command=(bash -c 'cd "$1" || exit; setup=$2; shift 2; if [ -n "$setup" ]; then eval "$setup" || { echo "flowrun: job setup failed: $setup" >&2; exit 1; }; fi; exec env -- "$@"'
           flowrun-job "$PWD" "${FLOWRUN_JOB_SETUP:-}" "${job_env[@]}" "${command[@]}")
  
  flowrun::debug "@submit: scheduler=$scheduler, queue=$queue, np=$np, options=$options, cmd=${command[*]}"
  
  # Load backend and submit
  flowrun::load_queue_backend "$scheduler" || return 1
  
  jobid=$(flowrun::backend_submit_job "$queue" "$np" "$output_file" "$depends_on" "$options" "${command[@]}") || return 1
  jobid="$scheduler:$jobid"
  
  # Track job
  echo "$jobid" >> "$FLOWRUN_SESSION_FILE" 2>/dev/null || true
  
  flowrun::debug "@submit: submitted job $jobid"
  echo "$jobid"
  return 0
}
