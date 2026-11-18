#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# runflow core library. Three ways to use it:
#   runflow [OPTIONS] script.sh        run a workflow script
#   runflow [OPTIONS] -c @directive    run one command
#   source lib/runflow.sh              load the directives into a script, then
#                                      optionally: runflow::setup [OPTIONS]
#
# Directives are modules: core ones in lib/directives/ (cannot be redefined),
# bundled extensions in lib/extensions/, then user and site extensions from
# the directories in RUNFLOW_DIRECTIVE_PATH (later ones replace earlier ones).
# See docs/DIRECTIVES.md.
#
# Workflow defaults, set by runflow::setup / the runflow options (all optional):
#   RUNFLOW_NP, RUNFLOW_QUEUE, RUNFLOW_SCHEDULER, RUNFLOW_DEPENDS_ON  - queue options
#   RUNFLOW_<SCHEDULER>_OPTIONS, RUNFLOW_MPI_OPTIONS  - native options
#   RUNFLOW_DRY_RUN=true  - directives print what they would do instead
# Set by @submit inside jobs: RUNFLOW_JOB_SCHEDULER (selects the MPI launcher)

# Load once: a script that sources the library may itself be run by runflow
if [[ -n "${_RUNFLOW_LOADED:-}" ]]; then
  return 0
fi

RUNFLOW_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# runflow's version: the VERSION file, which each release changes (semantic
# versioning, see CHANGELOG.md)
read -r _RUNFLOW_VERSION 2> /dev/null < "$RUNFLOW_HOME/VERSION" || _RUNFLOW_VERSION=unknown

source "$RUNFLOW_HOME/lib/common.sh" || return 1
source "$RUNFLOW_HOME/lib/config.sh" || return 1
runflow::debug "runflow $_RUNFLOW_VERSION ($RUNFLOW_HOME)"

# runflow's version, and for a Git checkout that is not exactly the release,
# where it is: "0.1.0", or e.g. "0.1.0 (git v0.1.0-3-g842f3b2-modified)"
# (3 commits after the release's tag, with local changes). Git is asked only
# here: runflow --version.
runflow::version() {
  local described=""
  if [[ -e "$RUNFLOW_HOME/.git" ]] && command -v git > /dev/null; then
    described=$(git -C "$RUNFLOW_HOME" describe --tags --always --dirty=-modified --match 'v[0-9]*' 2> /dev/null)
  fi
  if [[ -z "$described" || "$described" == "v$_RUNFLOW_VERSION" ]]; then
    echo "$_RUNFLOW_VERSION"
  else
    echo "$_RUNFLOW_VERSION (git $described)"
  fi
}

# Track submitted jobs in current session. A file (not an array) so that jobs
# submitted from subshells, e.g. job=$(@submit ...), are tracked too.
# The host is part of the name: machines sharing HOME can reuse process IDs.
RUNFLOW_SESSION_FILE="${RUNFLOW_STATE_DIR}/session.${HOSTNAME%%.*}.$$"

# Remove the job lists of this host's sessions that ended without cleaning up
# (interactive shells set no EXIT trap; killed workflows)
for _RUNFLOW_FILE in "$RUNFLOW_STATE_DIR/session.${HOSTNAME%%.*}."*; do
  _RUNFLOW_PID=${_RUNFLOW_FILE#"$RUNFLOW_STATE_DIR/session.${HOSTNAME%%.*}."}
  _RUNFLOW_PID=${_RUNFLOW_PID%.reported}
  if [[ "$_RUNFLOW_PID" =~ ^[0-9]+$ && "$_RUNFLOW_PID" != "$$" ]] && ! kill -0 "$_RUNFLOW_PID" 2> /dev/null; then
    rm -f "$_RUNFLOW_FILE"
  fi
done
unset _RUNFLOW_FILE _RUNFLOW_PID

# --- Helpers for directives (stable API, see docs/DIRECTIVES.md) -----------

# Dry run (runflow --dry-run): directives check their arguments and print what
# they would do (to stderr, so job=$(@submit ...) still gets an ID) instead of
# submitting, waiting, cancelling or running anything. Problems become warnings.
runflow::dry_run() {
  [[ "${RUNFLOW_DRY_RUN:-false}" == true ]]
}

runflow::dry() {
  echo "[DRY-RUN] $*" >&2
}

# Print arguments shell-quoted on one line
runflow::quoted() {
  local q
  printf -v q '%q ' "$@"
  echo "${q% }"
}

# Split an option string into words with shell quoting, in plain bash (no
# xargs: BSD and GNU differ; nothing is expanded or executed, no eval):
#   '...'   literal;  "..."  a backslash escapes " \ $ ` only;
#   outside quotes: a backslash escapes the next character, whitespace
#   separates words; '' and "" are empty words.
# Usage: runflow::split_options "STRING" [WHAT]  -> words in _RUNFLOW_WORDS;
# returns 1, naming WHAT, for an unclosed quote or a trailing backslash
runflow::split_options() {
  local string="$1" what="${2:-options}" word="" quote="" in_word=false c i
  _RUNFLOW_WORDS=()

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
          $in_word && _RUNFLOW_WORDS+=("$word")
          word="" in_word=false
          ;;
        \'|\") quote=$c in_word=true ;;
        \\)
          if (( i + 1 >= ${#string} )); then
            runflow::error "Trailing backslash in $what: $string"
            _RUNFLOW_WORDS=()
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
    runflow::error "Unbalanced quotes in $what: $string"
    _RUNFLOW_WORDS=()
    return 1
  fi
  ! $in_word || _RUNFLOW_WORDS+=("$word")
}

# Scheduler named by a --<scheduler>-options option (e.g. --slurm-options ->
# slurm); an error for unknown schedulers. The backend checks the options
runflow::options_scheduler() {
  local name=${1#--}
  name=${name%-options}
  if ! runflow::validate_scheduler "$name" 2> /dev/null; then
    runflow::error "Unknown option: $1 (native scheduler options exist for: lsf, slurm, pbs, localq)"
    return 1
  fi
  echo "$name"
}

# Job IDs returned by @submit are qualified with their scheduler, e.g.
# "localq:12" or "slurm:4567", so directives can route them to the right backend.
# A bare ID (e.g. "12") belongs to the given default scheduler.
# Usage: runflow::parse_jobid JOBID [DEFAULT_SCHEDULER]  -> sets _RUNFLOW_JOB_SCHEDULER and _RUNFLOW_JOB_ID
runflow::parse_jobid() {
  local jobid="$1" default_scheduler="${2:-}"

  if [[ -z "$jobid" ]]; then
    runflow::error "No job ID provided (empty, e.g. from a failed job=\$(@submit ...))"
    return 1
  fi
  if [[ "$jobid" == *:* ]]; then
    _RUNFLOW_JOB_SCHEDULER="${jobid%%:*}"
    _RUNFLOW_JOB_ID="${jobid#*:}"
    if ! runflow::validate_scheduler "$_RUNFLOW_JOB_SCHEDULER" 2>/dev/null; then
      runflow::error "Invalid job ID '$jobid': unknown scheduler '$_RUNFLOW_JOB_SCHEDULER'"
      return 1
    fi
  else
    _RUNFLOW_JOB_SCHEDULER=${default_scheduler:-$(runflow::get_scheduler)} || return 1
    _RUNFLOW_JOB_ID="$jobid"
  fi

  if [[ -z "$_RUNFLOW_JOB_ID" ]]; then
    runflow::error "Invalid job ID '$jobid'"
    return 1
  fi
}

# Print this session's job IDs, one per line
runflow::session_jobs() {
  [[ -f "$RUNFLOW_SESSION_FILE" ]] && grep -v '^$' "$RUNFLOW_SESSION_FILE"
}

# In interactive shells: a job whose final state was already shown (by @wait
# or @cancel), so that job notifications do not repeat it
runflow::mark_reported() {
  [[ -n "${_RUNFLOW_INTERACTIVE:-}" ]] || return 0
  echo "$1" >> "$RUNFLOW_SESSION_FILE.reported" 2> /dev/null
}

# --- Directive modules -------------------------------------------------------

declare -gA _RUNFLOW_DIRECTIVE_USAGE=() _RUNFLOW_DIRECTIVE_SUMMARY=()
declare -gA _RUNFLOW_DIRECTIVE_KIND=() _RUNFLOW_DIRECTIVE_FILE=()
declare -gA _RUNFLOW_DIRECTIVE_OPTIONS=()
declare -gA _RUNFLOW_SETTING_VAR=() _RUNFLOW_SETTING_DESCRIPTION=() _RUNFLOW_SETTING_DIRECTIVE=()
declare -gA _RUNFLOW_SETTING_KIND=() _RUNFLOW_DIRECTIVE_OPTION_LIST=() _RUNFLOW_DIRECTIVE_ARGS=()
declare -ga _RUNFLOW_DIRECTIVE_ORDER=()

# Register directive @NAME (called by its module when loaded):
#   runflow::directive NAME "USAGE" "SUMMARY" ["OPTIONS"]
# OPTIONS, if given, says what --NAME-options means for this directive (e.g.
# "Flow options for every @flow"); the directive reads them with
# runflow::directive_options. Core directives cannot be redefined; a later
# extension replaces an earlier one.
runflow::directive() {
  local name="$1" usage="$2" summary="$3" options="${4:-}"
  local kind="${_RUNFLOW_LOADING_KIND:-extension}" file="${_RUNFLOW_LOADING_FILE:-${BASH_SOURCE[1]:-}}"

  # --<name>-options must stay unambiguous
  if runflow::validate_scheduler "$name" 2> /dev/null; then
    runflow::error "$file: @$name: the name of a scheduler cannot be used for a directive"
    return 1
  fi

  if [[ "${_RUNFLOW_DIRECTIVE_KIND[$name]:-}" == core && "$kind" != core ]]; then
    runflow::error "$file: @$name is a core directive and cannot be redefined"
    _RUNFLOW_CORE_CLASHES+=" $name"  # restored after the module (runflow::load_module)
    return 1
  fi

  if [[ -n "${_RUNFLOW_DIRECTIVE_KIND[$name]:-}" ]]; then
    runflow::debug "@$name from $file replaces the one from ${_RUNFLOW_DIRECTIVE_FILE[$name]}"
  else
    _RUNFLOW_DIRECTIVE_ORDER+=("$name")
  fi
  _RUNFLOW_DIRECTIVE_USAGE[$name]="$usage"
  _RUNFLOW_DIRECTIVE_SUMMARY[$name]="$summary"
  _RUNFLOW_DIRECTIVE_KIND[$name]="$kind"
  _RUNFLOW_DIRECTIVE_FILE[$name]="$file"
  _RUNFLOW_DIRECTIVE_OPTIONS[$name]="$options"
  _RUNFLOW_DIRECTIVE_OPTION_LIST[$name]=""
  _RUNFLOW_DIRECTIVE_ARGS[$name]=""
  _RUNFLOW_LAST_DIRECTIVE="$name"
}

# Declare an option of the directive registered last, for @help and
# Tab completion (the directive still parses its arguments itself):
#   runflow::directive_option "NAMES [VALUE]" KIND "DESCRIPTION"
# NAMES are the spellings, comma-separated ("-v, --flow-version"); VALUE names the
# value the option takes; KIND says how to complete it: version (a Flow
# version), deck, file, job (this run's job IDs), scheduler, text (not
# completed), or - for an option without a value. E.g.
#   runflow::directive_option "-v, --flow-version VERSION" version "Flow version: a name or a path"
runflow::directive_option() {
  local spec="$1" kind="$2" description="$3" name="${_RUNFLOW_LAST_DIRECTIVE:-}"
  if [[ -z "$name" ]]; then
    runflow::error "runflow::directive_option: call it after runflow::directive"
    return 1
  fi
  _RUNFLOW_DIRECTIVE_OPTION_LIST[$name]+="$spec"$'\t'"$kind"$'\t'"$description"$'\n'
}

# Declare what the arguments after the options of the directive registered
# last are, for Tab completion: deck, file, job, command (a program or a
# directive), directive, or none. Default: file.
runflow::directive_arguments() {
  _RUNFLOW_DIRECTIVE_ARGS[${_RUNFLOW_LAST_DIRECTIVE:-}]="$1"
}

# The spellings of a declared option ("-v, --flow-version VERSION": -v --flow-version)
runflow::option_names() {
  local word names=()
  for word in $1; do
    [[ "$word" == -* ]] && names+=("${word%,}")
  done
  echo "${names[*]}"
}

# Register a workflow setting of the directive registered last (called by its
# module after runflow::directive):
#   runflow::directive_setting OPTION VARIABLE "DESCRIPTION" [KIND]
# KIND is how to complete the value (see runflow::directive_option; default
# text). runflow and runflow::setup then accept --OPTION VALUE, which sets and
# exports VARIABLE; @submit passes it to jobs. E.g. @flow registers
#   runflow::directive_setting flow-version RUNFLOW_FLOW_VERSION "..."
# Give VARIABLE its site default in the configuration in the form
# VARIABLE="${VARIABLE-default}", so that jobs keep the workflow's value.
runflow::directive_setting() {
  local option="$1" var="$2" description="$3" kind="${4:-text}"

  case "$option" in
    np|queue|scheduler|depends-on|directives|dry-run|command|jobs|help|shell|library|*-options)
      runflow::error "@${_RUNFLOW_LAST_DIRECTIVE:-?}: --$option is reserved and cannot be a directive setting"
      return 1
      ;;
  esac

  _RUNFLOW_SETTING_VAR[$option]="$var"
  _RUNFLOW_SETTING_DESCRIPTION[$option]="$description"
  _RUNFLOW_SETTING_DIRECTIVE[$option]="${_RUNFLOW_LAST_DIRECTIVE:-}"
  _RUNFLOW_SETTING_KIND[$option]="$kind"
}

# For a directive's option loop: does option $2 have its value? An error
# naming @DIRECTIVE if not.  Usage: runflow::has_value @NAME "$@" || return 1
runflow::has_value() {
  [[ $# -ge 3 ]] && return 0
  runflow::error "$1: option $2 needs a value"
  return 1
}

# Variable holding the --NAME-options of a directive or scheduler, e.g.
# flow -> RUNFLOW_FLOW_OPTIONS, my-tool -> RUNFLOW_MY_TOOL_OPTIONS
runflow::options_var() {
  local name="${1^^}"
  echo "RUNFLOW_${name//[^A-Z0-9]/_}_OPTIONS"
}

# Options for every invocation of directive NAME (configuration, then
# runflow --NAME-options / runflow::setup), split into _RUNFLOW_WORDS
runflow::directive_options() {
  local var
  var=$(runflow::options_var "$1")
  runflow::split_options "${!var:-}" "--$1-options"
}

# Load one module file: runflow::load_module FILE [core|extension]. A module
# that tries to register a core directive is refused (runflow::directive), and
# that core directive is loaded again afterwards, undoing what the module
# defined for it.
runflow::load_module() {
  local file="$1" kind="${2:-extension}" name

  _RUNFLOW_LOADING_FILE="$file"
  _RUNFLOW_LOADING_KIND="$kind"
  _RUNFLOW_CORE_CLASHES=""
  source "$file" || runflow::error "Could not load directive module: $file"
  unset _RUNFLOW_LOADING_FILE _RUNFLOW_LOADING_KIND

  for name in $_RUNFLOW_CORE_CLASHES; do
    runflow::load_module "$RUNFLOW_HOME/lib/directives/$name.sh" core
  done
}

# Load every *.sh module of a directory (or one file), in name order: byte
# order, whatever the locale (en_US sorts flowpy.sh before flow.sh), so @help
# and the messages list directives the same way everywhere
runflow::load_modules() {
  local path="$1" kind="${2:-extension}" file files

  if [[ -f "$path" ]]; then
    runflow::load_module "$path" "$kind"
    return
  fi
  files=$(LC_COLLATE=C; printf '%s\n' "$path"/*.sh)
  while IFS= read -r file; do
    [[ -f "$file" ]] && runflow::load_module "$file" "$kind"
  done <<< "$files"
}

# Load extension modules (directories or files) into this workflow, and add
# them to RUNFLOW_DIRECTIVE_PATH so jobs submitted from it load them too
runflow::use() {
  local path abs

  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      runflow::error "Directive module or directory not found: $path"
      return 1
    fi
    abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    runflow::load_modules "$abs" extension
    export RUNFLOW_DIRECTIVE_PATH="${RUNFLOW_DIRECTIVE_PATH:+$RUNFLOW_DIRECTIVE_PATH:}$abs"
  done
  # Interactive shells: complete the new directives too
  ! declare -F runflow::register_completion > /dev/null || runflow::register_completion
}

# Settings that shape how directives behave, which @submit passes to every job
# explicitly (sites do not always pass the submitting environment on):
# configuration file, extension modules, scheduler, debug, the options of
# every directive that takes --<name>-options, and directive settings. The
# workflow's other submit defaults (queue, dependencies, native options) are
# not passed; @submit sets RUNFLOW_NP to the job's own process count.
runflow::job_variables() {
  local name
  echo RUNFLOW_CONFIG RUNFLOW_DIRECTIVE_PATH RUNFLOW_SCHEDULER RUNFLOW_DEBUG
  for name in "${_RUNFLOW_DIRECTIVE_ORDER[@]}"; do
    [[ -n "${_RUNFLOW_DIRECTIVE_OPTIONS[$name]}" ]] && runflow::options_var "$name"
  done
  for name in "${!_RUNFLOW_SETTING_VAR[@]}"; do
    echo "${_RUNFLOW_SETTING_VAR[$name]}"
  done
}

# Names of the directives that take --<name>-options
runflow::directives_with_options() {
  local name names=()
  for name in "${_RUNFLOW_DIRECTIVE_ORDER[@]}"; do
    [[ -n "${_RUNFLOW_DIRECTIVE_OPTIONS[$name]}" ]] && names+=("$name")
  done
  echo "${names[*]}"
}

# List the loaded directives with their summaries: core first, then
# extensions (for @help and runflow -h)
runflow::directive_help() {
  local kind name width=4
  for name in "${_RUNFLOW_DIRECTIVE_ORDER[@]}"; do
    (( ${#name} + 1 > width )) && width=$(( ${#name} + 1 ))
  done
  for kind in core extension; do
    for name in "${_RUNFLOW_DIRECTIVE_ORDER[@]}"; do
      [[ "${_RUNFLOW_DIRECTIVE_KIND[$name]}" == "$kind" ]] || continue
      printf '  %-*s  %s\n' "$width" "@$name" "${_RUNFLOW_DIRECTIVE_SUMMARY[$name]}"
    done
  done
}

# The help of directive @NAME: usage, summary, options, the defaults that apply
# to it (--NAME-options, settings), and where to read more
runflow::directive_details() {
  local name="$1" spec kind description setting width=6 rows=() defaults=() row
  printf '@%s %s\n  %s\n' "$name" "${_RUNFLOW_DIRECTIVE_USAGE[$name]}" "${_RUNFLOW_DIRECTIVE_SUMMARY[$name]}"

  while IFS=$'\t' read -r spec kind description; do
    [[ -n "$spec" ]] || continue
    rows+=("$spec"$'\t'"$description")
    (( ${#spec} > width )) && width=${#spec}
  done <<< "${_RUNFLOW_DIRECTIVE_OPTION_LIST[$name]}"

  if [[ -n "${_RUNFLOW_DIRECTIVE_OPTIONS[$name]}" ]]; then
    defaults+=("--$name-options OPTS"$'\t'"${_RUNFLOW_DIRECTIVE_OPTIONS[$name]}")
  fi
  for setting in "${!_RUNFLOW_SETTING_DIRECTIVE[@]}"; do
    [[ "${_RUNFLOW_SETTING_DIRECTIVE[$setting]}" == "$name" ]] || continue
    spec=${setting##*-}
    defaults+=("--$setting ${spec^^}"$'\t'"${_RUNFLOW_SETTING_DESCRIPTION[$setting]}")
  done
  for row in "${defaults[@]}"; do
    spec=${row%%$'\t'*}
    (( ${#spec} > width )) && width=${#spec}
  done
  (( width <= 24 )) || width=24

  if [[ ${#rows[@]} -gt 0 ]]; then
    printf '\nOptions:\n'
    runflow::print_rows "$width" "${rows[@]}"
  fi
  if [[ ${#defaults[@]} -gt 0 ]]; then
    printf '\nDefaults for every @%s (options of runflow and runflow::setup):\n' "$name"
    runflow::print_rows "$width" "${defaults[@]}"
  fi

  if [[ "${_RUNFLOW_DIRECTIVE_FILE[$name]}" == "$RUNFLOW_HOME"/lib/* ]]; then
    printf '\nFull reference: %s\n' "$(runflow::man_command "$name")"
  else
    printf '\nDefined in %s\n' "${_RUNFLOW_DIRECTIVE_FILE[$name]}"
  fi
}

# A command that opens the man page, at directive @NAME's section if given:
# man runflow when man finds the page, else man with the page's path. less
# (man's usual pager) gets a search for the section's heading in LESS; other
# pagers ignore it. ("$" would end the option in LESS: the heading's indent of
# three spaces is what tells it from other mentions.)
runflow::man_command() {
  local name="${1:-}" page=runflow
  man -w runflow > /dev/null 2>&1 || page="$RUNFLOW_HOME/man/man1/runflow.1"
  if [[ -n "$name" ]]; then
    printf "LESS='+/^   @%s' man %q\n" "$name" "$page"
  else
    printf 'man %q\n' "$page"
  fi
}

# Print "SPEC<TAB>DESCRIPTION" rows in two columns, the first WIDTH wide; a
# longer SPEC gets its description on the next line
runflow::print_rows() {
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
# Usage: runflow::unknown_option NAME OPTION [HINT]; returns 1
runflow::unknown_option() {
  runflow::error "@$1: unknown option: $2 (@help @$1 shows the options${3:+; $3})"
  return 1
}

# --- Workflow setup ------------------------------------------------------------

# Apply one workflow option (the options of the runflow command that are not
# about how to run it). Sets _RUNFLOW_SHIFT to the number of arguments used,
# 0 if $1 is not a workflow option; returns 1 on errors.
runflow::setup_option() {
  _RUNFLOW_SHIFT=0

  # Settings registered by directives (runflow::directive_setting)
  if [[ "$1" == --* && -n "${_RUNFLOW_SETTING_VAR[${1#--}]:-}" ]]; then
    if [[ $# -lt 2 ]]; then
      runflow::error "Option $1 needs a value"
      return 1
    fi
    export "${_RUNFLOW_SETTING_VAR[${1#--}]}=$2"
    _RUNFLOW_SHIFT=2
    return 0
  fi

  case "$1" in
    -n|--np|-q|--queue|-s|--scheduler|--depends-on|--*-options|--directives)
      if [[ $# -lt 2 ]]; then
        runflow::error "Option $1 needs a value"
        return 1
      fi
      ;;
  esac

  case "$1" in
    -n|--np) export RUNFLOW_NP="$2" ;;
    -q|--queue) export RUNFLOW_QUEUE="$2" ;;
    -s|--scheduler) export RUNFLOW_SCHEDULER="$2" ;;
    --depends-on)
      if [[ -z "${2//[ ,]/}" ]]; then
        runflow::error "--depends-on needs a job ID (got: '$2')"
        return 1
      fi
      export RUNFLOW_DEPENDS_ON="${RUNFLOW_DEPENDS_ON:+$RUNFLOW_DEPENDS_ON,}$2"
      ;;
    --directives)
      runflow::use "$2" || return 1
      ;;
    --*-options)
      # --<scheduler>-options (native options for that scheduler's jobs) or
      # --<directive>-options (options for every invocation of the directive),
      # added to the configuration's RUNFLOW_<NAME>_OPTIONS and exported so
      # that directives running inside jobs get them too
      local name=${1#--} var
      name=${name%-options}
      if [[ -z "${_RUNFLOW_DIRECTIVE_OPTIONS[$name]:-}" ]]; then
        if [[ -n "${_RUNFLOW_DIRECTIVE_KIND[$name]:-}" ]]; then
          runflow::error "Unknown option: $1 (@$name takes no options)"
          return 1
        fi
        runflow::options_scheduler "$1" > /dev/null || {
          runflow::error "Directive options exist for: $(runflow::directives_with_options)"
          return 1
        }
      fi
      var=$(runflow::options_var "$name")
      export "$var=${!var:+${!var} }$2"
      ;;
    --dry-run)
      export RUNFLOW_DRY_RUN=true
      _RUNFLOW_SHIFT=1
      return 0
      ;;
    *)
      return 0
      ;;
  esac
  _RUNFLOW_SHIFT=2
}

# Configure the workflow with the same options as the runflow command, e.g.
#   runflow::setup -s localq -n 8 --slurm-options "--time=1:00:00" --dry-run
# and turn on workflow mode (see runflow::workflow_mode), except in
# interactive shells
runflow::setup() {
  while [[ $# -gt 0 ]]; do
    runflow::setup_option "$@" || return 1
    if [[ "$_RUNFLOW_SHIFT" -eq 0 ]]; then
      runflow::error "runflow::setup: unknown option: $1"
      return 1
    fi
    shift "$_RUNFLOW_SHIFT"
  done
  [[ $- == *i* ]] || runflow::workflow_mode
}

# Workflow mode: forget this run's job list on exit (also on HUP/INT/PIPE/TERM;
# jobs already submitted keep running), and stop the workflow on an unknown
# directive. On for runflow and for scripts that source the library; not for
# interactive shells, whose traps it would take over.
runflow::workflow_mode() {
  [[ -z "${_RUNFLOW_WORKFLOW_MODE:-}" ]] || return 0
  _RUNFLOW_WORKFLOW_MODE=true
  RUNFLOW_WORKFLOW_PID=$$

  trap 'runflow::workflow_exit' EXIT
  trap 'runflow::workflow_signal HUP 129' HUP
  trap 'runflow::workflow_signal INT 130' INT
  trap 'runflow::workflow_signal PIPE 141' PIPE
  trap 'runflow::workflow_signal TERM 143' TERM
  trap 'exit 127' USR1  # sent by command_not_found_handle

  # A signal ignored when bash started cannot be trapped (bash keeps it
  # ignored, e.g. HUP under nohup): the workflow then does not stop on it
  if [[ "${RUNFLOW_DEBUG:-}" == true ]]; then
    local sig
    for sig in HUP INT PIPE TERM; do
      [[ "$(trap -p "$sig")" == *workflow_signal* ]] ||
        runflow::debug "SIG$sig was ignored when this shell started: the workflow ignores it too"
    done
  fi
}

# A trapped signal in workflow mode: exit with STATUS (128 + its number), which
# runs the exit handler. Further signals are ignored from here on, as in the
# exit handler: one arriving before it starts would run this again, and the
# second exit would end bash without running the exit handler at all.
# Usage: runflow::workflow_signal NAME STATUS
runflow::workflow_signal() {
  trap '' HUP INT PIPE TERM
  runflow::debug "SIG$1 received: exiting with status $2"
  exit "$2"
}

# Exit handler of workflow mode: the standard clean-up idiom. Further signals
# are ignored, so that nothing interrupts the clean-up: they often come in
# twos (timeout signals the command, then its process group; a closing
# terminal, every process), and the commands it runs (rm) inherit that. What
# a signal that cannot be handled (kill -9) leaves behind is harmless: each
# run reads only its own session file, and the next runflow on this host
# removes those of ended runs (see the top).
runflow::workflow_exit() {
  local rc=$? njobs=0
  trap '' HUP INT PIPE TERM

  # The count is only printed in dry runs (counting forks)
  runflow::dry_run && njobs=$(( $(runflow::session_jobs | wc -l) ))  # BSD wc pads with spaces
  # Remove first: printing can fail (e.g. closed pipe) and end the handler
  if rm -f "$RUNFLOW_SESSION_FILE" "$RUNFLOW_SESSION_FILE.reported"; then
    runflow::debug "Exit handler (status $rc): removed ${RUNFLOW_SESSION_FILE##*/}"
  else
    runflow::debug "Exit handler (status $rc): could not remove ${RUNFLOW_SESSION_FILE##*/}"
  fi

  if runflow::dry_run && [[ $rc -eq 0 ]]; then
    runflow::dry "done: $njobs job(s) would be submitted; nothing was submitted"
  elif runflow::dry_run; then
    runflow::dry "stopped (exit status $rc) after $njobs job(s); nothing was submitted"
  fi
}

# --- Unknown directives ----------------------------------------------------------

# Keep any existing handler (e.g. a distro's command-not-found) for other commands
if declare -f command_not_found_handle >/dev/null && ! declare -f runflow::prev_command_not_found_handle >/dev/null; then
  eval "$(declare -f command_not_found_handle | sed '1s/command_not_found_handle/runflow::prev_command_not_found_handle/')"
fi

# Unknown @directive: clear error, and in workflow mode stop the workflow.
# Bash runs this handler in a subshell, so it signals the workflow's process
# (RUNFLOW_WORKFLOW_PID) instead of exiting.
command_not_found_handle() {
  if [[ "$1" != @* ]]; then
    if declare -f runflow::prev_command_not_found_handle >/dev/null; then
      runflow::prev_command_not_found_handle "$@"
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

  runflow::error "Unknown directive: $1${suggestion:+ (did you mean $suggestion?)}"
  [[ -n "${RUNFLOW_WORKFLOW_PID:-}" ]] && kill -USR1 "$RUNFLOW_WORKFLOW_PID" 2>/dev/null
  return 127
}

# --- Startup -------------------------------------------------------------------------

runflow::ensure_state_dirs

runflow::load_modules "$RUNFLOW_HOME/lib/directives" core
runflow::load_modules "$RUNFLOW_HOME/lib/extensions" extension
IFS=: read -r -a _RUNFLOW_PATHS <<< "${RUNFLOW_DIRECTIVE_PATH:-}"
for _RUNFLOW_PATH in "${_RUNFLOW_PATHS[@]}"; do
  if [[ -e "$_RUNFLOW_PATH" ]]; then
    runflow::load_modules "$_RUNFLOW_PATH" extension
  elif [[ -n "$_RUNFLOW_PATH" ]]; then
    runflow::debug "Directive path not found, skipped: $_RUNFLOW_PATH"
  fi
done
unset _RUNFLOW_PATHS _RUNFLOW_PATH

_RUNFLOW_LOADED=true

# Scripts that source the library get workflow mode; the runflow command turns
# it on itself, and interactive shells get the interactive features instead
if [[ $- == *i* ]]; then
  source "$RUNFLOW_HOME/lib/interactive.sh"
elif [[ -z "${_RUNFLOW_CLI:-}" ]]; then
  runflow::workflow_mode
fi
