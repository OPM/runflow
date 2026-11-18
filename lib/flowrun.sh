#!/usr/bin/env bash
# flowrun core library. Three ways to use it:
#   flowrun [OPTIONS] script.sh        run a workflow script
#   flowrun [OPTIONS] -c @directive    run one command
#   source lib/flowrun.sh              load the directives into a script, then
#                                      optionally: flowrun::setup [OPTIONS]
#
# Directives are modules: core ones in lib/directives/ (cannot be redefined),
# bundled extensions in lib/extensions/, then user and site extensions from
# the directories in FLOWRUN_DIRECTIVE_PATH (later ones replace earlier ones).
# See docs/DIRECTIVES.md.
#
# Workflow defaults, set by flowrun::setup / the flowrun options (all optional):
#   FLOWRUN_NP, FLOWRUN_QUEUE, FLOWRUN_SCHEDULER, FLOWRUN_DEPENDS_ON  - queue options
#   FLOWRUN_<SCHEDULER>_OPTIONS, FLOWRUN_MPI_OPTIONS  - native options
#   FLOWRUN_DRY_RUN=true  - directives print what they would do instead
# Set by @submit inside jobs: FLOWRUN_JOB_SCHEDULER (selects the MPI launcher)

# Load once: a script that sources the library may itself be run by flowrun
if [[ -n "${_FLOWRUN_LOADED:-}" ]]; then
  return 0
fi

FLOWRUN_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$FLOWRUN_HOME/lib/common.sh" || return 1
source "$FLOWRUN_HOME/lib/config.sh" || return 1

# Track submitted jobs in current session. A file (not an array) so that jobs
# submitted from subshells, e.g. job=$(@submit ...), are tracked too.
# The host is part of the name: machines sharing HOME can reuse process IDs.
FLOWRUN_SESSION_FILE="${FLOWRUN_STATE_DIR}/session.${HOSTNAME%%.*}.$$"

# Remove the job lists of this host's sessions that ended without cleaning up
# (interactive shells set no EXIT trap; killed workflows)
for _FLOWRUN_FILE in "$FLOWRUN_STATE_DIR/session.${HOSTNAME%%.*}."*; do
  _FLOWRUN_PID=${_FLOWRUN_FILE#"$FLOWRUN_STATE_DIR/session.${HOSTNAME%%.*}."}
  _FLOWRUN_PID=${_FLOWRUN_PID%.reported}
  if [[ "$_FLOWRUN_PID" =~ ^[0-9]+$ && "$_FLOWRUN_PID" != "$$" ]] && ! kill -0 "$_FLOWRUN_PID" 2> /dev/null; then
    rm -f "$_FLOWRUN_FILE"
  fi
done
unset _FLOWRUN_FILE _FLOWRUN_PID

# --- Helpers for directives (stable API, see docs/DIRECTIVES.md) -----------

# Dry run (flowrun --dry-run): directives check their arguments and print what
# they would do (to stderr, so job=$(@submit ...) still gets an ID) instead of
# submitting, waiting, cancelling or running anything. Problems become warnings.
flowrun::dry_run() {
  [[ "${FLOWRUN_DRY_RUN:-false}" == true ]]
}

flowrun::dry() {
  echo "[DRY-RUN] $*" >&2
}

# Print arguments shell-quoted on one line
flowrun::quoted() {
  local q
  printf -v q '%q ' "$@"
  echo "${q% }"
}

# Split an option string into words with shell quoting, in plain bash (no
# xargs: BSD and GNU differ; nothing is expanded or executed, no eval):
#   '...'   literal;  "..."  a backslash escapes " \ $ ` only;
#   outside quotes: a backslash escapes the next character, whitespace
#   separates words; '' and "" are empty words.
# Usage: flowrun::split_options "STRING" [WHAT]  -> words in _FLOWRUN_WORDS;
# returns 1, naming WHAT, for an unclosed quote or a trailing backslash
flowrun::split_options() {
  local string="$1" what="${2:-options}" word="" quote="" in_word=false c i
  _FLOWRUN_WORDS=()

  for (( i = 0; i < ${#string}; i++ )); do
    c=${string:i:1}
    if [[ "$quote" == "'" ]]; then
      if [[ "$c" == "'" ]]; then quote=""; else word+=$c; fi
    elif [[ "$quote" == '"' ]]; then
      if [[ "$c" == '"' ]]; then
        quote=""
      elif [[ "$c" == '\' && "${string:i+1:1}" == [\"\\\$\`] ]]; then
        word+=${string:i+1:1}
        (( i++ ))
      else
        word+=$c
      fi
    else
      case "$c" in
        [[:space:]])
          $in_word && _FLOWRUN_WORDS+=("$word")
          word="" in_word=false
          ;;
        \'|\") quote=$c in_word=true ;;
        \\)
          if (( i + 1 >= ${#string} )); then
            flowrun::error "Trailing backslash in $what: $string"
            _FLOWRUN_WORDS=()
            return 1
          fi
          word+=${string:i+1:1} in_word=true
          (( i++ ))
          ;;
        *) word+=$c in_word=true ;;
      esac
    fi
  done

  if [[ -n "$quote" ]]; then
    flowrun::error "Unbalanced quotes in $what: $string"
    _FLOWRUN_WORDS=()
    return 1
  fi
  ! $in_word || _FLOWRUN_WORDS+=("$word")
}

# Scheduler named by a --<scheduler>-options option (e.g. --slurm-options ->
# slurm); an error for unknown schedulers. The backend checks the options
flowrun::options_scheduler() {
  local name=${1#--}
  name=${name%-options}
  if ! flowrun::validate_scheduler "$name" 2> /dev/null; then
    flowrun::error "Unknown option: $1 (native scheduler options exist for: lsf, slurm, pbs, localq)"
    return 1
  fi
  echo "$name"
}

# Job IDs returned by @submit are qualified with their scheduler, e.g.
# "localq:12" or "slurm:4567", so directives can route them to the right backend.
# A bare ID (e.g. "12") belongs to the given default scheduler.
# Usage: flowrun::parse_jobid JOBID [DEFAULT_SCHEDULER]  -> sets _FLOWRUN_JOB_SCHEDULER and _FLOWRUN_JOB_ID
flowrun::parse_jobid() {
  local jobid="$1" default_scheduler="${2:-}"

  if [[ -z "$jobid" ]]; then
    flowrun::error "No job ID provided (empty, e.g. from a failed job=\$(@submit ...))"
    return 1
  fi
  if [[ "$jobid" == *:* ]]; then
    _FLOWRUN_JOB_SCHEDULER="${jobid%%:*}"
    _FLOWRUN_JOB_ID="${jobid#*:}"
    if ! flowrun::validate_scheduler "$_FLOWRUN_JOB_SCHEDULER" 2>/dev/null; then
      flowrun::error "Invalid job ID '$jobid': unknown scheduler '$_FLOWRUN_JOB_SCHEDULER'"
      return 1
    fi
  else
    _FLOWRUN_JOB_SCHEDULER=${default_scheduler:-$(flowrun::get_scheduler)} || return 1
    _FLOWRUN_JOB_ID="$jobid"
  fi

  if [[ -z "$_FLOWRUN_JOB_ID" ]]; then
    flowrun::error "Invalid job ID '$jobid'"
    return 1
  fi
}

# Print this session's job IDs, one per line
flowrun::session_jobs() {
  [[ -f "$FLOWRUN_SESSION_FILE" ]] && grep -v '^$' "$FLOWRUN_SESSION_FILE"
}

# In interactive shells: a job whose final state was already shown (by @wait
# or @cancel), so that job notifications do not repeat it
flowrun::mark_reported() {
  [[ -n "${_FLOWRUN_INTERACTIVE:-}" ]] || return 0
  echo "$1" >> "$FLOWRUN_SESSION_FILE.reported" 2> /dev/null
}

# --- Directive modules -------------------------------------------------------

declare -gA _FLOWRUN_DIRECTIVE_USAGE=() _FLOWRUN_DIRECTIVE_SUMMARY=()
declare -gA _FLOWRUN_DIRECTIVE_KIND=() _FLOWRUN_DIRECTIVE_FILE=()
declare -gA _FLOWRUN_DIRECTIVE_OPTIONS=()
declare -gA _FLOWRUN_SETTING_VAR=() _FLOWRUN_SETTING_DESCRIPTION=() _FLOWRUN_SETTING_DIRECTIVE=()
declare -gA _FLOWRUN_SETTING_KIND=() _FLOWRUN_DIRECTIVE_OPTION_LIST=() _FLOWRUN_DIRECTIVE_ARGS=()
declare -ga _FLOWRUN_DIRECTIVE_ORDER=()

# Register directive @NAME (called by its module when loaded):
#   flowrun::directive NAME "USAGE" "SUMMARY" ["OPTIONS"]
# OPTIONS, if given, says what --NAME-options means for this directive (e.g.
# "Flow options for every @flow"); the directive reads them with
# flowrun::directive_options. Core directives cannot be redefined; a later
# extension replaces an earlier one.
flowrun::directive() {
  local name="$1" usage="$2" summary="$3" options="${4:-}"
  local kind="${_FLOWRUN_LOADING_KIND:-extension}" file="${_FLOWRUN_LOADING_FILE:-${BASH_SOURCE[1]:-}}"

  # --<name>-options must stay unambiguous
  if flowrun::validate_scheduler "$name" 2> /dev/null; then
    flowrun::error "$file: @$name: the name of a scheduler cannot be used for a directive"
    return 1
  fi

  if [[ "${_FLOWRUN_DIRECTIVE_KIND[$name]:-}" == core && "$kind" != core ]]; then
    flowrun::error "$file: @$name is a core directive and cannot be redefined"
    _FLOWRUN_CORE_CLASHES+=" $name"  # restored after the module (flowrun::load_module)
    return 1
  fi

  if [[ -n "${_FLOWRUN_DIRECTIVE_KIND[$name]:-}" ]]; then
    flowrun::debug "@$name from $file replaces the one from ${_FLOWRUN_DIRECTIVE_FILE[$name]}"
  else
    _FLOWRUN_DIRECTIVE_ORDER+=("$name")
  fi
  _FLOWRUN_DIRECTIVE_USAGE[$name]="$usage"
  _FLOWRUN_DIRECTIVE_SUMMARY[$name]="$summary"
  _FLOWRUN_DIRECTIVE_KIND[$name]="$kind"
  _FLOWRUN_DIRECTIVE_FILE[$name]="$file"
  _FLOWRUN_DIRECTIVE_OPTIONS[$name]="$options"
  _FLOWRUN_DIRECTIVE_OPTION_LIST[$name]=""
  _FLOWRUN_DIRECTIVE_ARGS[$name]=""
  _FLOWRUN_LAST_DIRECTIVE="$name"
}

# Declare an option of the directive registered last, for @help and
# Tab completion (the directive still parses its arguments itself):
#   flowrun::directive_option "NAMES [VALUE]" KIND "DESCRIPTION"
# NAMES are the spellings, comma-separated ("-v, --flow-version"); VALUE names the
# value the option takes; KIND says how to complete it: version (a Flow
# version), deck, file, job (this run's job IDs), scheduler, text (not
# completed), or - for an option without a value. E.g.
#   flowrun::directive_option "-v, --flow-version VERSION" version "Flow version: a name or a path"
flowrun::directive_option() {
  local spec="$1" kind="$2" description="$3" name="${_FLOWRUN_LAST_DIRECTIVE:-}"
  if [[ -z "$name" ]]; then
    flowrun::error "flowrun::directive_option: call it after flowrun::directive"
    return 1
  fi
  _FLOWRUN_DIRECTIVE_OPTION_LIST[$name]+="$spec"$'\t'"$kind"$'\t'"$description"$'\n'
}

# Declare what the arguments after the options of the directive registered
# last are, for Tab completion: deck, file, job, command (a program or a
# directive), directive, or none. Default: file.
flowrun::directive_arguments() {
  _FLOWRUN_DIRECTIVE_ARGS[${_FLOWRUN_LAST_DIRECTIVE:-}]="$1"
}

# The spellings of a declared option ("-v, --flow-version VERSION": -v --flow-version)
flowrun::option_names() {
  local word names=()
  for word in $1; do
    [[ "$word" == -* ]] && names+=("${word%,}")
  done
  echo "${names[*]}"
}

# Register a workflow setting of the directive registered last (called by its
# module after flowrun::directive):
#   flowrun::directive_setting OPTION VARIABLE "DESCRIPTION" [KIND]
# KIND is how to complete the value (see flowrun::directive_option; default
# text). flowrun and flowrun::setup then accept --OPTION VALUE, which sets and
# exports VARIABLE; @submit passes it to jobs. E.g. @flow registers
#   flowrun::directive_setting flow-version FLOWRUN_FLOW_VERSION "..."
# Give VARIABLE its site default in the configuration in the form
# VARIABLE="${VARIABLE-default}", so that jobs keep the workflow's value.
flowrun::directive_setting() {
  local option="$1" var="$2" description="$3" kind="${4:-text}"

  case "$option" in
    np|queue|scheduler|depends-on|directives|dry-run|command|jobs|help|shell|library|*-options)
      flowrun::error "@${_FLOWRUN_LAST_DIRECTIVE:-?}: --$option is reserved and cannot be a directive setting"
      return 1
      ;;
  esac

  _FLOWRUN_SETTING_VAR[$option]="$var"
  _FLOWRUN_SETTING_DESCRIPTION[$option]="$description"
  _FLOWRUN_SETTING_DIRECTIVE[$option]="${_FLOWRUN_LAST_DIRECTIVE:-}"
  _FLOWRUN_SETTING_KIND[$option]="$kind"
}

# For a directive's option loop: does option $2 have its value? An error
# naming @DIRECTIVE if not.  Usage: flowrun::has_value @NAME "$@" || return 1
flowrun::has_value() {
  [[ $# -ge 3 ]] && return 0
  flowrun::error "$1: option $2 needs a value"
  return 1
}

# Variable holding the --NAME-options of a directive or scheduler, e.g.
# flow -> FLOWRUN_FLOW_OPTIONS, my-tool -> FLOWRUN_MY_TOOL_OPTIONS
flowrun::options_var() {
  local name="${1^^}"
  echo "FLOWRUN_${name//[^A-Z0-9]/_}_OPTIONS"
}

# Options for every invocation of directive NAME (configuration, then
# flowrun --NAME-options / flowrun::setup), split into _FLOWRUN_WORDS
flowrun::directive_options() {
  local var
  var=$(flowrun::options_var "$1")
  flowrun::split_options "${!var:-}" "--$1-options"
}

# Load one module file: flowrun::load_module FILE [core|extension]. A module
# that tries to register a core directive is refused (flowrun::directive), and
# that core directive is loaded again afterwards, undoing what the module
# defined for it.
flowrun::load_module() {
  local file="$1" kind="${2:-extension}" name

  _FLOWRUN_LOADING_FILE="$file"
  _FLOWRUN_LOADING_KIND="$kind"
  _FLOWRUN_CORE_CLASHES=""
  source "$file" || flowrun::error "Could not load directive module: $file"
  unset _FLOWRUN_LOADING_FILE _FLOWRUN_LOADING_KIND

  for name in $_FLOWRUN_CORE_CLASHES; do
    flowrun::load_module "$FLOWRUN_HOME/lib/directives/$name.sh" core
  done
}

# Load every *.sh module of a directory (or one file), in name order: byte
# order, whatever the locale (en_US sorts flowpy.sh before flow.sh), so @help
# and the messages list directives the same way everywhere
flowrun::load_modules() {
  local path="$1" kind="${2:-extension}" file files

  if [[ -f "$path" ]]; then
    flowrun::load_module "$path" "$kind"
    return
  fi
  files=$(LC_COLLATE=C; printf '%s\n' "$path"/*.sh)
  while IFS= read -r file; do
    [[ -f "$file" ]] && flowrun::load_module "$file" "$kind"
  done <<< "$files"
}

# Load extension modules (directories or files) into this workflow, and add
# them to FLOWRUN_DIRECTIVE_PATH so jobs submitted from it load them too
flowrun::use() {
  local path abs

  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      flowrun::error "Directive module or directory not found: $path"
      return 1
    fi
    abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    flowrun::load_modules "$abs" extension
    export FLOWRUN_DIRECTIVE_PATH="${FLOWRUN_DIRECTIVE_PATH:+$FLOWRUN_DIRECTIVE_PATH:}$abs"
  done
  # Interactive shells: complete the new directives too
  ! declare -F flowrun::register_completion > /dev/null || flowrun::register_completion
}

# Settings that shape how directives behave, which @submit passes to every job
# explicitly (sites do not always pass the submitting environment on):
# configuration file, extension modules, scheduler, debug, the options of
# every directive that takes --<name>-options, and directive settings. The
# workflow's other submit defaults (queue, dependencies, native options) are
# not passed; @submit sets FLOWRUN_NP to the job's own process count.
flowrun::job_variables() {
  local name
  echo FLOWRUN_CONFIG FLOWRUN_DIRECTIVE_PATH FLOWRUN_SCHEDULER FLOWRUN_DEBUG
  for name in "${_FLOWRUN_DIRECTIVE_ORDER[@]}"; do
    [[ -n "${_FLOWRUN_DIRECTIVE_OPTIONS[$name]}" ]] && flowrun::options_var "$name"
  done
  for name in "${!_FLOWRUN_SETTING_VAR[@]}"; do
    echo "${_FLOWRUN_SETTING_VAR[$name]}"
  done
}

# Names of the directives that take --<name>-options
flowrun::directives_with_options() {
  local name names=()
  for name in "${_FLOWRUN_DIRECTIVE_ORDER[@]}"; do
    [[ -n "${_FLOWRUN_DIRECTIVE_OPTIONS[$name]}" ]] && names+=("$name")
  done
  echo "${names[*]}"
}

# List the loaded directives with their summaries: core first, then
# extensions (for @help and flowrun -h)
flowrun::directive_help() {
  local kind name width=4
  for name in "${_FLOWRUN_DIRECTIVE_ORDER[@]}"; do
    (( ${#name} + 1 > width )) && width=$(( ${#name} + 1 ))
  done
  for kind in core extension; do
    for name in "${_FLOWRUN_DIRECTIVE_ORDER[@]}"; do
      [[ "${_FLOWRUN_DIRECTIVE_KIND[$name]}" == "$kind" ]] || continue
      printf '  %-*s  %s\n' "$width" "@$name" "${_FLOWRUN_DIRECTIVE_SUMMARY[$name]}"
    done
  done
}

# The help of directive @NAME: usage, summary, options, the defaults that apply
# to it (--NAME-options, settings), and where to read more
flowrun::directive_details() {
  local name="$1" spec kind description setting width=6 rows=() defaults=() row
  printf '@%s %s\n  %s\n' "$name" "${_FLOWRUN_DIRECTIVE_USAGE[$name]}" "${_FLOWRUN_DIRECTIVE_SUMMARY[$name]}"

  while IFS=$'\t' read -r spec kind description; do
    [[ -n "$spec" ]] || continue
    rows+=("$spec"$'\t'"$description")
    (( ${#spec} > width )) && width=${#spec}
  done <<< "${_FLOWRUN_DIRECTIVE_OPTION_LIST[$name]}"

  if [[ -n "${_FLOWRUN_DIRECTIVE_OPTIONS[$name]}" ]]; then
    defaults+=("--$name-options OPTS"$'\t'"${_FLOWRUN_DIRECTIVE_OPTIONS[$name]}")
  fi
  for setting in "${!_FLOWRUN_SETTING_DIRECTIVE[@]}"; do
    [[ "${_FLOWRUN_SETTING_DIRECTIVE[$setting]}" == "$name" ]] || continue
    spec=${setting##*-}
    defaults+=("--$setting ${spec^^}"$'\t'"${_FLOWRUN_SETTING_DESCRIPTION[$setting]}")
  done
  for row in "${defaults[@]}"; do
    spec=${row%%$'\t'*}
    (( ${#spec} > width )) && width=${#spec}
  done
  (( width <= 24 )) || width=24

  if [[ ${#rows[@]} -gt 0 ]]; then
    printf '\nOptions:\n'
    flowrun::print_rows "$width" "${rows[@]}"
  fi
  if [[ ${#defaults[@]} -gt 0 ]]; then
    printf '\nDefaults for every @%s (options of flowrun and flowrun::setup):\n' "$name"
    flowrun::print_rows "$width" "${defaults[@]}"
  fi

  if [[ "${_FLOWRUN_DIRECTIVE_FILE[$name]}" == "$FLOWRUN_HOME"/lib/* ]]; then
    printf '\nFull reference: %s\n' "$(flowrun::man_command "$name")"
  else
    printf '\nDefined in %s\n' "${_FLOWRUN_DIRECTIVE_FILE[$name]}"
  fi
}

# A command that opens the man page, at directive @NAME's section if given:
# man flowrun when man finds the page, else man with the page's path. less
# (man's usual pager) gets a search for the section's heading in LESS; other
# pagers ignore it. ("$" would end the option in LESS: the heading's indent of
# three spaces is what tells it from other mentions.)
flowrun::man_command() {
  local name="${1:-}" page=flowrun
  man -w flowrun > /dev/null 2>&1 || page="$FLOWRUN_HOME/man/man1/flowrun.1"
  if [[ -n "$name" ]]; then
    printf "LESS='+/^   @%s' man %q\n" "$name" "$page"
  else
    printf 'man %q\n' "$page"
  fi
}

# Print "SPEC<TAB>DESCRIPTION" rows in two columns, the first WIDTH wide; a
# longer SPEC gets its description on the next line
flowrun::print_rows() {
  local width="$1" row spec
  shift
  for row in "$@"; do
    spec=${row%%$'\t'*}
    if (( ${#spec} > width )); then
      printf '  %s\n  %-*s  %s\n' "$spec" "$width" "" "${row#*$'\t'}"
    else
      printf '  %-*s  %s\n' "$width" "$spec" "${row#*$'\t'}"
    fi
  done
}

# For directives: report an option @NAME does not take, pointing to its help
# (@help @NAME is the only help: @NAME --help would be ambiguous for
# directives such as @flow, whose options go to their program).
# Usage: flowrun::unknown_option NAME OPTION [HINT]; returns 1
flowrun::unknown_option() {
  flowrun::error "@$1: unknown option: $2 (@help @$1 shows the options${3:+; $3})"
  return 1
}

# --- Workflow setup ------------------------------------------------------------

# Apply one workflow option (the options of the flowrun command that are not
# about how to run it). Sets _FLOWRUN_SHIFT to the number of arguments used,
# 0 if $1 is not a workflow option; returns 1 on errors.
flowrun::setup_option() {
  _FLOWRUN_SHIFT=0

  # Settings registered by directives (flowrun::directive_setting)
  if [[ "$1" == --* && -n "${_FLOWRUN_SETTING_VAR[${1#--}]:-}" ]]; then
    if [[ $# -lt 2 ]]; then
      flowrun::error "Option $1 needs a value"
      return 1
    fi
    export "${_FLOWRUN_SETTING_VAR[${1#--}]}=$2"
    _FLOWRUN_SHIFT=2
    return 0
  fi

  case "$1" in
    -n|--np|-q|--queue|-s|--scheduler|--depends-on|--*-options|--directives)
      if [[ $# -lt 2 ]]; then
        flowrun::error "Option $1 needs a value"
        return 1
      fi
      ;;
  esac

  case "$1" in
    -n|--np) export FLOWRUN_NP="$2" ;;
    -q|--queue) export FLOWRUN_QUEUE="$2" ;;
    -s|--scheduler) export FLOWRUN_SCHEDULER="$2" ;;
    --depends-on)
      if [[ -z "${2//[ ,]/}" ]]; then
        flowrun::error "--depends-on needs a job ID (got: '$2')"
        return 1
      fi
      export FLOWRUN_DEPENDS_ON="${FLOWRUN_DEPENDS_ON:+$FLOWRUN_DEPENDS_ON,}$2"
      ;;
    --directives)
      flowrun::use "$2" || return 1
      ;;
    --*-options)
      # --<scheduler>-options (native options for that scheduler's jobs) or
      # --<directive>-options (options for every invocation of the directive),
      # added to the configuration's FLOWRUN_<NAME>_OPTIONS and exported so
      # that directives running inside jobs get them too
      local name=${1#--} var
      name=${name%-options}
      if [[ -z "${_FLOWRUN_DIRECTIVE_OPTIONS[$name]:-}" ]]; then
        if [[ -n "${_FLOWRUN_DIRECTIVE_KIND[$name]:-}" ]]; then
          flowrun::error "Unknown option: $1 (@$name takes no options)"
          return 1
        fi
        flowrun::options_scheduler "$1" > /dev/null || {
          flowrun::error "Directive options exist for: $(flowrun::directives_with_options)"
          return 1
        }
      fi
      var=$(flowrun::options_var "$name")
      export "$var=${!var:+${!var} }$2"
      ;;
    --dry-run)
      export FLOWRUN_DRY_RUN=true
      _FLOWRUN_SHIFT=1
      return 0
      ;;
    *)
      return 0
      ;;
  esac
  _FLOWRUN_SHIFT=2
}

# Configure the workflow with the same options as the flowrun command, e.g.
#   flowrun::setup -s localq -n 8 --slurm-options "--time=1:00:00" --dry-run
# and turn on workflow mode (see flowrun::workflow_mode), except in
# interactive shells
flowrun::setup() {
  while [[ $# -gt 0 ]]; do
    flowrun::setup_option "$@" || return 1
    if [[ "$_FLOWRUN_SHIFT" -eq 0 ]]; then
      flowrun::error "flowrun::setup: unknown option: $1"
      return 1
    fi
    shift "$_FLOWRUN_SHIFT"
  done
  [[ $- == *i* ]] || flowrun::workflow_mode
}

# Workflow mode: forget this run's job list on exit (also on HUP/INT/PIPE/TERM;
# jobs already submitted keep running), and stop the workflow on an unknown
# directive. On for flowrun and for scripts that source the library; not for
# interactive shells, whose traps it would take over.
flowrun::workflow_mode() {
  [[ -z "${_FLOWRUN_WORKFLOW_MODE:-}" ]] || return 0
  _FLOWRUN_WORKFLOW_MODE=true
  FLOWRUN_WORKFLOW_PID=$$

  trap 'flowrun::workflow_exit' EXIT
  trap 'flowrun::workflow_signal HUP 129' HUP
  trap 'flowrun::workflow_signal INT 130' INT
  trap 'flowrun::workflow_signal PIPE 141' PIPE
  trap 'flowrun::workflow_signal TERM 143' TERM
  trap 'exit 127' USR1  # sent by command_not_found_handle

  # A signal ignored when bash started cannot be trapped (bash keeps it
  # ignored, e.g. HUP under nohup): the workflow then does not stop on it
  if [[ "${FLOWRUN_DEBUG:-}" == true ]]; then
    local sig
    for sig in HUP INT PIPE TERM; do
      [[ "$(trap -p "$sig")" == *workflow_signal* ]] ||
        flowrun::debug "SIG$sig was ignored when this shell started: the workflow ignores it too"
    done
  fi
}

# A trapped signal in workflow mode: exit with STATUS (128 + its number), which
# runs the exit handler. Further signals are ignored from here on, as in the
# exit handler: one arriving before it starts would run this again, and the
# second exit would end bash without running the exit handler at all.
# Usage: flowrun::workflow_signal NAME STATUS
flowrun::workflow_signal() {
  trap '' HUP INT PIPE TERM
  flowrun::debug "SIG$1 received: exiting with status $2"
  exit "$2"
}

# Exit handler of workflow mode: the standard clean-up idiom. Further signals
# are ignored, so that nothing interrupts the clean-up: they often come in
# twos (timeout signals the command, then its process group; a closing
# terminal, every process), and the commands it runs (rm) inherit that. What
# a signal that cannot be handled (kill -9) leaves behind is harmless: each
# run reads only its own session file, and the next flowrun on this host
# removes those of ended runs (see the top).
flowrun::workflow_exit() {
  local rc=$? njobs=0
  trap '' HUP INT PIPE TERM

  # The count is only printed in dry runs (counting forks)
  flowrun::dry_run && njobs=$(( $(flowrun::session_jobs | wc -l) ))  # BSD wc pads with spaces
  # Remove first: printing can fail (e.g. closed pipe) and end the handler
  if rm -f "$FLOWRUN_SESSION_FILE" "$FLOWRUN_SESSION_FILE.reported"; then
    flowrun::debug "Exit handler (status $rc): removed ${FLOWRUN_SESSION_FILE##*/}"
  else
    flowrun::debug "Exit handler (status $rc): could not remove ${FLOWRUN_SESSION_FILE##*/}"
  fi

  if flowrun::dry_run && [[ $rc -eq 0 ]]; then
    flowrun::dry "done: $njobs job(s) would be submitted; nothing was submitted"
  elif flowrun::dry_run; then
    flowrun::dry "stopped (exit status $rc) after $njobs job(s); nothing was submitted"
  fi
}

# --- Unknown directives ----------------------------------------------------------

# Keep any existing handler (e.g. a distro's command-not-found) for other commands
if declare -f command_not_found_handle >/dev/null && ! declare -f flowrun::prev_command_not_found_handle >/dev/null; then
  eval "$(declare -f command_not_found_handle | sed '1s/command_not_found_handle/flowrun::prev_command_not_found_handle/')"
fi

# Unknown @directive: clear error, and in workflow mode stop the workflow.
# Bash runs this handler in a subshell, so it signals the workflow's process
# (FLOWRUN_WORKFLOW_PID) instead of exiting.
command_not_found_handle() {
  if [[ "$1" != @* ]]; then
    if declare -f flowrun::prev_command_not_found_handle >/dev/null; then
      flowrun::prev_command_not_found_handle "$@"
      return
    fi
    echo "bash: $1: command not found" >&2
    return 127
  fi

  # Suggest the directive sharing the longest prefix (at least one letter)
  local directive suggestion best=1 len
  for directive in $(compgen -A function -- @); do
    len=0
    while [[ $len -lt ${#1} && "${1:len:1}" == "${directive:len:1}" ]]; do
      len=$((len + 1))
    done
    if [[ $len -gt $best ]]; then
      best=$len
      suggestion=$directive
    fi
  done

  flowrun::error "Unknown directive: $1${suggestion:+ (did you mean $suggestion?)}"
  [[ -n "${FLOWRUN_WORKFLOW_PID:-}" ]] && kill -USR1 "$FLOWRUN_WORKFLOW_PID" 2>/dev/null
  return 127
}

# --- Startup -------------------------------------------------------------------------

flowrun::ensure_state_dirs

flowrun::load_modules "$FLOWRUN_HOME/lib/directives" core
flowrun::load_modules "$FLOWRUN_HOME/lib/extensions" extension
IFS=: read -r -a _FLOWRUN_PATHS <<< "${FLOWRUN_DIRECTIVE_PATH:-}"
for _FLOWRUN_PATH in "${_FLOWRUN_PATHS[@]}"; do
  if [[ -e "$_FLOWRUN_PATH" ]]; then
    flowrun::load_modules "$_FLOWRUN_PATH" extension
  elif [[ -n "$_FLOWRUN_PATH" ]]; then
    flowrun::debug "Directive path not found, skipped: $_FLOWRUN_PATH"
  fi
done
unset _FLOWRUN_PATHS _FLOWRUN_PATH

_FLOWRUN_LOADED=true

# Scripts that source the library get workflow mode; the flowrun command turns
# it on itself, and interactive shells get the interactive features instead
if [[ $- == *i* ]]; then
  source "$FLOWRUN_HOME/lib/interactive.sh"
elif [[ -z "${_FLOWRUN_CLI:-}" ]]; then
  flowrun::workflow_mode
fi
