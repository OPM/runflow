#!/usr/bin/env bash
# opmexec core library. Three ways to use it:
#   opmexec [OPTIONS] script.sh        run a workflow script
#   opmexec [OPTIONS] -c @directive    run one command
#   source lib/opmexec.sh              load the directives into a script, then
#                                      optionally: opmexec::setup [OPTIONS]
#
# Directives are modules: core ones in lib/directives/ (cannot be redefined),
# bundled extensions in lib/extensions/, then user and site extensions from
# the directories in OPMEXEC_DIRECTIVE_PATH (later ones replace earlier ones).
# See docs/DIRECTIVES.md.
#
# Workflow defaults, set by opmexec::setup / the opmexec options (all optional):
#   OPMEXEC_NP, OPMEXEC_QUEUE, OPMEXEC_SCHEDULER, OPMEXEC_DEPENDS_ON  - queue options
#   OPMEXEC_<SCHEDULER>_OPTIONS, OPMEXEC_MPI_OPTIONS  - native options
#   OPMEXEC_DRY_RUN=true  - directives print what they would do instead
# Set by @submit inside jobs: OPMEXEC_JOB_SCHEDULER (selects the MPI launcher)

# Load once: a script that sources the library may itself be run by opmexec
if [[ -n "${_OPMEXEC_LOADED:-}" ]]; then
  return 0
fi

OPMEXEC_HOME="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

source "$OPMEXEC_HOME/lib/common.sh" || return 1
source "$OPMEXEC_HOME/lib/config.sh" || return 1

# Track submitted jobs in current session. A file (not an array) so that jobs
# submitted from subshells, e.g. job=$(@submit ...), are tracked too.
# The host is part of the name: machines sharing HOME can reuse process IDs.
OPMEXEC_SESSION_FILE="${OPMEXEC_STATE_DIR}/session.${HOSTNAME%%.*}.$$"

# Remove the job lists of this host's sessions that ended without cleaning up
# (interactive shells set no EXIT trap; killed workflows)
for _OPMEXEC_FILE in "$OPMEXEC_STATE_DIR/session.${HOSTNAME%%.*}."*; do
  _OPMEXEC_PID=${_OPMEXEC_FILE#"$OPMEXEC_STATE_DIR/session.${HOSTNAME%%.*}."}
  _OPMEXEC_PID=${_OPMEXEC_PID%.reported}
  if [[ "$_OPMEXEC_PID" =~ ^[0-9]+$ && "$_OPMEXEC_PID" != "$$" ]] && ! kill -0 "$_OPMEXEC_PID" 2> /dev/null; then
    rm -f "$_OPMEXEC_FILE"
  fi
done
unset _OPMEXEC_FILE _OPMEXEC_PID

# --- Helpers for directives (stable API, see docs/DIRECTIVES.md) -----------

# Dry run (opmexec --dry-run): directives check their arguments and print what
# they would do (to stderr, so job=$(@submit ...) still gets an ID) instead of
# submitting, waiting, cancelling or running anything. Problems become warnings.
opmexec::dry_run() {
  [[ "${OPMEXEC_DRY_RUN:-false}" == true ]]
}

opmexec::dry() {
  echo "[DRY-RUN] $*" >&2
}

# Print arguments shell-quoted on one line
opmexec::quoted() {
  local q
  printf -v q '%q ' "$@"
  echo "${q% }"
}

# Split an option string into words with shell quoting, in plain bash (no
# xargs: BSD and GNU differ; nothing is expanded or executed, no eval):
#   '...'   literal;  "..."  a backslash escapes " \ $ ` only;
#   outside quotes: a backslash escapes the next character, whitespace
#   separates words; '' and "" are empty words.
# Usage: opmexec::split_options "STRING" [WHAT]  -> words in _OPMEXEC_WORDS;
# returns 1, naming WHAT, for an unclosed quote or a trailing backslash
opmexec::split_options() {
  local string="$1" what="${2:-options}" word="" quote="" in_word=false c i
  _OPMEXEC_WORDS=()

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
          $in_word && _OPMEXEC_WORDS+=("$word")
          word="" in_word=false
          ;;
        \'|\") quote=$c in_word=true ;;
        \\)
          if (( i + 1 >= ${#string} )); then
            opmexec::error "Trailing backslash in $what: $string"
            _OPMEXEC_WORDS=()
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
    opmexec::error "Unbalanced quotes in $what: $string"
    _OPMEXEC_WORDS=()
    return 1
  fi
  ! $in_word || _OPMEXEC_WORDS+=("$word")
}

# Scheduler named by a --<scheduler>-options option (e.g. --slurm-options ->
# slurm); an error for unknown schedulers. The backend checks the options
opmexec::options_scheduler() {
  local name=${1#--}
  name=${name%-options}
  if ! opmexec::validate_scheduler "$name" 2> /dev/null; then
    opmexec::error "Unknown option: $1 (native scheduler options exist for: lsf, slurm, pbs, localq)"
    return 1
  fi
  echo "$name"
}

# Job IDs returned by @submit are qualified with their scheduler, e.g.
# "localq:12" or "slurm:4567", so directives can route them to the right backend.
# A bare ID (e.g. "12") belongs to the given default scheduler.
# Usage: opmexec::parse_jobid JOBID [DEFAULT_SCHEDULER]  -> sets _OPMEXEC_JOB_SCHEDULER and _OPMEXEC_JOB_ID
opmexec::parse_jobid() {
  local jobid="$1" default_scheduler="${2:-}"

  if [[ -z "$jobid" ]]; then
    opmexec::error "No job ID provided (empty, e.g. from a failed job=\$(@submit ...))"
    return 1
  fi
  if [[ "$jobid" == *:* ]]; then
    _OPMEXEC_JOB_SCHEDULER="${jobid%%:*}"
    _OPMEXEC_JOB_ID="${jobid#*:}"
    if ! opmexec::validate_scheduler "$_OPMEXEC_JOB_SCHEDULER" 2>/dev/null; then
      opmexec::error "Invalid job ID '$jobid': unknown scheduler '$_OPMEXEC_JOB_SCHEDULER'"
      return 1
    fi
  else
    _OPMEXEC_JOB_SCHEDULER=${default_scheduler:-$(opmexec::get_scheduler)} || return 1
    _OPMEXEC_JOB_ID="$jobid"
  fi

  if [[ -z "$_OPMEXEC_JOB_ID" ]]; then
    opmexec::error "Invalid job ID '$jobid'"
    return 1
  fi
}

# Print this session's job IDs, one per line
opmexec::session_jobs() {
  [[ -f "$OPMEXEC_SESSION_FILE" ]] && grep -v '^$' "$OPMEXEC_SESSION_FILE"
}

# In interactive shells: a job whose final state was already shown (by @wait
# or @cancel), so that job notifications do not repeat it
opmexec::mark_reported() {
  [[ -n "${_OPMEXEC_INTERACTIVE:-}" ]] || return 0
  echo "$1" >> "$OPMEXEC_SESSION_FILE.reported" 2> /dev/null
}

# --- Directive modules -------------------------------------------------------

declare -gA _OPMEXEC_DIRECTIVE_USAGE=() _OPMEXEC_DIRECTIVE_SUMMARY=()
declare -gA _OPMEXEC_DIRECTIVE_KIND=() _OPMEXEC_DIRECTIVE_FILE=()
declare -gA _OPMEXEC_DIRECTIVE_OPTIONS=()
declare -gA _OPMEXEC_SETTING_VAR=() _OPMEXEC_SETTING_DESCRIPTION=() _OPMEXEC_SETTING_DIRECTIVE=()
declare -gA _OPMEXEC_SETTING_KIND=() _OPMEXEC_DIRECTIVE_OPTION_LIST=() _OPMEXEC_DIRECTIVE_ARGS=()
declare -ga _OPMEXEC_DIRECTIVE_ORDER=()

# Register directive @NAME (called by its module when loaded):
#   opmexec::directive NAME "USAGE" "SUMMARY" ["OPTIONS"]
# OPTIONS, if given, says what --NAME-options means for this directive (e.g.
# "Flow options for every @flow"); the directive reads them with
# opmexec::directive_options. Core directives cannot be redefined; a later
# extension replaces an earlier one.
opmexec::directive() {
  local name="$1" usage="$2" summary="$3" options="${4:-}"
  local kind="${_OPMEXEC_LOADING_KIND:-extension}" file="${_OPMEXEC_LOADING_FILE:-${BASH_SOURCE[1]:-}}"

  # --<name>-options must stay unambiguous
  if opmexec::validate_scheduler "$name" 2> /dev/null; then
    opmexec::error "$file: @$name: the name of a scheduler cannot be used for a directive"
    return 1
  fi

  if [[ "${_OPMEXEC_DIRECTIVE_KIND[$name]:-}" == core && "$kind" != core ]]; then
    opmexec::error "$file: @$name is a core directive and cannot be redefined"
    _OPMEXEC_CORE_CLASHES+=" $name"  # restored after the module (opmexec::load_module)
    return 1
  fi

  if [[ -n "${_OPMEXEC_DIRECTIVE_KIND[$name]:-}" ]]; then
    opmexec::debug "@$name from $file replaces the one from ${_OPMEXEC_DIRECTIVE_FILE[$name]}"
  else
    _OPMEXEC_DIRECTIVE_ORDER+=("$name")
  fi
  _OPMEXEC_DIRECTIVE_USAGE[$name]="$usage"
  _OPMEXEC_DIRECTIVE_SUMMARY[$name]="$summary"
  _OPMEXEC_DIRECTIVE_KIND[$name]="$kind"
  _OPMEXEC_DIRECTIVE_FILE[$name]="$file"
  _OPMEXEC_DIRECTIVE_OPTIONS[$name]="$options"
  _OPMEXEC_DIRECTIVE_OPTION_LIST[$name]=""
  _OPMEXEC_DIRECTIVE_ARGS[$name]=""
  _OPMEXEC_LAST_DIRECTIVE="$name"
}

# Declare an option of the directive registered last, for @help and
# Tab completion (the directive still parses its arguments itself):
#   opmexec::directive_option "NAMES [VALUE]" KIND "DESCRIPTION"
# NAMES are the spellings, comma-separated ("-v, --flow-version"); VALUE names the
# value the option takes; KIND says how to complete it: version (a Flow
# version), deck, file, job (this run's job IDs), scheduler, text (not
# completed), or - for an option without a value. E.g.
#   opmexec::directive_option "-v, --flow-version VERSION" version "Flow version: a name or a path"
opmexec::directive_option() {
  local spec="$1" kind="$2" description="$3" name="${_OPMEXEC_LAST_DIRECTIVE:-}"
  if [[ -z "$name" ]]; then
    opmexec::error "opmexec::directive_option: call it after opmexec::directive"
    return 1
  fi
  _OPMEXEC_DIRECTIVE_OPTION_LIST[$name]+="$spec"$'\t'"$kind"$'\t'"$description"$'\n'
}

# Declare what the arguments after the options of the directive registered
# last are, for Tab completion: deck, file, job, command (a program or a
# directive), directive, or none. Default: file.
opmexec::directive_arguments() {
  _OPMEXEC_DIRECTIVE_ARGS[${_OPMEXEC_LAST_DIRECTIVE:-}]="$1"
}

# The spellings of a declared option ("-v, --flow-version VERSION": -v --flow-version)
opmexec::option_names() {
  local word names=()
  for word in $1; do
    [[ "$word" == -* ]] && names+=("${word%,}")
  done
  echo "${names[*]}"
}

# Register a workflow setting of the directive registered last (called by its
# module after opmexec::directive):
#   opmexec::directive_setting OPTION VARIABLE "DESCRIPTION" [KIND]
# KIND is how to complete the value (see opmexec::directive_option; default
# text). opmexec and opmexec::setup then accept --OPTION VALUE, which sets and
# exports VARIABLE; @submit passes it to jobs. E.g. @flow registers
#   opmexec::directive_setting flow-version OPMEXEC_FLOW_VERSION "..."
# Give VARIABLE its site default in the configuration in the form
# VARIABLE="${VARIABLE-default}", so that jobs keep the workflow's value.
opmexec::directive_setting() {
  local option="$1" var="$2" description="$3" kind="${4:-text}"

  case "$option" in
    np|queue|scheduler|depends-on|directives|dry-run|command|jobs|help|shell|library|*-options)
      opmexec::error "@${_OPMEXEC_LAST_DIRECTIVE:-?}: --$option is reserved and cannot be a directive setting"
      return 1
      ;;
  esac

  _OPMEXEC_SETTING_VAR[$option]="$var"
  _OPMEXEC_SETTING_DESCRIPTION[$option]="$description"
  _OPMEXEC_SETTING_DIRECTIVE[$option]="${_OPMEXEC_LAST_DIRECTIVE:-}"
  _OPMEXEC_SETTING_KIND[$option]="$kind"
}

# For a directive's option loop: does option $2 have its value? An error
# naming @DIRECTIVE if not.  Usage: opmexec::has_value @NAME "$@" || return 1
opmexec::has_value() {
  [[ $# -ge 3 ]] && return 0
  opmexec::error "$1: option $2 needs a value"
  return 1
}

# Variable holding the --NAME-options of a directive or scheduler, e.g.
# flow -> OPMEXEC_FLOW_OPTIONS, my-tool -> OPMEXEC_MY_TOOL_OPTIONS
opmexec::options_var() {
  local name="${1^^}"
  echo "OPMEXEC_${name//[^A-Z0-9]/_}_OPTIONS"
}

# Options for every invocation of directive NAME (configuration, then
# opmexec --NAME-options / opmexec::setup), split into _OPMEXEC_WORDS
opmexec::directive_options() {
  local var
  var=$(opmexec::options_var "$1")
  opmexec::split_options "${!var:-}" "--$1-options"
}

# Load one module file: opmexec::load_module FILE [core|extension]. A module
# that tries to register a core directive is refused (opmexec::directive), and
# that core directive is loaded again afterwards, undoing what the module
# defined for it.
opmexec::load_module() {
  local file="$1" kind="${2:-extension}" name

  _OPMEXEC_LOADING_FILE="$file"
  _OPMEXEC_LOADING_KIND="$kind"
  _OPMEXEC_CORE_CLASHES=""
  source "$file" || opmexec::error "Could not load directive module: $file"
  unset _OPMEXEC_LOADING_FILE _OPMEXEC_LOADING_KIND

  for name in $_OPMEXEC_CORE_CLASHES; do
    opmexec::load_module "$OPMEXEC_HOME/lib/directives/$name.sh" core
  done
}

# Load every *.sh module of a directory (or one file), in name order: byte
# order, whatever the locale (en_US sorts flowpy.sh before flow.sh), so @help
# and the messages list directives the same way everywhere
opmexec::load_modules() {
  local path="$1" kind="${2:-extension}" file files

  if [[ -f "$path" ]]; then
    opmexec::load_module "$path" "$kind"
    return
  fi
  files=$(LC_COLLATE=C; printf '%s\n' "$path"/*.sh)
  while IFS= read -r file; do
    [[ -f "$file" ]] && opmexec::load_module "$file" "$kind"
  done <<< "$files"
}

# Load extension modules (directories or files) into this workflow, and add
# them to OPMEXEC_DIRECTIVE_PATH so jobs submitted from it load them too
opmexec::use() {
  local path abs

  for path in "$@"; do
    if [[ ! -e "$path" ]]; then
      opmexec::error "Directive module or directory not found: $path"
      return 1
    fi
    abs="$(cd "$(dirname "$path")" && pwd)/$(basename "$path")"
    opmexec::load_modules "$abs" extension
    export OPMEXEC_DIRECTIVE_PATH="${OPMEXEC_DIRECTIVE_PATH:+$OPMEXEC_DIRECTIVE_PATH:}$abs"
  done
  # Interactive shells: complete the new directives too
  ! declare -F opmexec::register_completion > /dev/null || opmexec::register_completion
}

# Settings that shape how directives behave, which @submit passes to every job
# explicitly (sites do not always pass the submitting environment on):
# configuration file, extension modules, scheduler, debug, the options of
# every directive that takes --<name>-options, and directive settings. The
# workflow's other submit defaults (queue, dependencies, native options) are
# not passed; @submit sets OPMEXEC_NP to the job's own process count.
opmexec::job_variables() {
  local name
  echo OPMEXEC_CONFIG OPMEXEC_DIRECTIVE_PATH OPMEXEC_SCHEDULER OPMEXEC_DEBUG
  for name in "${_OPMEXEC_DIRECTIVE_ORDER[@]}"; do
    [[ -n "${_OPMEXEC_DIRECTIVE_OPTIONS[$name]}" ]] && opmexec::options_var "$name"
  done
  for name in "${!_OPMEXEC_SETTING_VAR[@]}"; do
    echo "${_OPMEXEC_SETTING_VAR[$name]}"
  done
}

# Names of the directives that take --<name>-options
opmexec::directives_with_options() {
  local name names=()
  for name in "${_OPMEXEC_DIRECTIVE_ORDER[@]}"; do
    [[ -n "${_OPMEXEC_DIRECTIVE_OPTIONS[$name]}" ]] && names+=("$name")
  done
  echo "${names[*]}"
}

# List the loaded directives with their summaries: core first, then
# extensions (for @help and opmexec -h)
opmexec::directive_help() {
  local kind name width=4
  for name in "${_OPMEXEC_DIRECTIVE_ORDER[@]}"; do
    (( ${#name} + 1 > width )) && width=$(( ${#name} + 1 ))
  done
  for kind in core extension; do
    for name in "${_OPMEXEC_DIRECTIVE_ORDER[@]}"; do
      [[ "${_OPMEXEC_DIRECTIVE_KIND[$name]}" == "$kind" ]] || continue
      printf '  %-*s  %s\n' "$width" "@$name" "${_OPMEXEC_DIRECTIVE_SUMMARY[$name]}"
    done
  done
}

# The help of directive @NAME: usage, summary, options, the defaults that apply
# to it (--NAME-options, settings), and where to read more
opmexec::directive_details() {
  local name="$1" spec kind description setting width=6 rows=() defaults=() row
  printf '@%s %s\n  %s\n' "$name" "${_OPMEXEC_DIRECTIVE_USAGE[$name]}" "${_OPMEXEC_DIRECTIVE_SUMMARY[$name]}"

  while IFS=$'\t' read -r spec kind description; do
    [[ -n "$spec" ]] || continue
    rows+=("$spec"$'\t'"$description")
    (( ${#spec} > width )) && width=${#spec}
  done <<< "${_OPMEXEC_DIRECTIVE_OPTION_LIST[$name]}"

  if [[ -n "${_OPMEXEC_DIRECTIVE_OPTIONS[$name]}" ]]; then
    defaults+=("--$name-options OPTS"$'\t'"${_OPMEXEC_DIRECTIVE_OPTIONS[$name]}")
  fi
  for setting in "${!_OPMEXEC_SETTING_DIRECTIVE[@]}"; do
    [[ "${_OPMEXEC_SETTING_DIRECTIVE[$setting]}" == "$name" ]] || continue
    spec=${setting##*-}
    defaults+=("--$setting ${spec^^}"$'\t'"${_OPMEXEC_SETTING_DESCRIPTION[$setting]}")
  done
  for row in "${defaults[@]}"; do
    spec=${row%%$'\t'*}
    (( ${#spec} > width )) && width=${#spec}
  done
  (( width <= 24 )) || width=24

  if [[ ${#rows[@]} -gt 0 ]]; then
    printf '\nOptions:\n'
    opmexec::print_rows "$width" "${rows[@]}"
  fi
  if [[ ${#defaults[@]} -gt 0 ]]; then
    printf '\nDefaults for every @%s (options of opmexec and opmexec::setup):\n' "$name"
    opmexec::print_rows "$width" "${defaults[@]}"
  fi

  if [[ "${_OPMEXEC_DIRECTIVE_FILE[$name]}" == "$OPMEXEC_HOME"/lib/* ]]; then
    printf '\nFull reference: %s\n' "$(opmexec::man_command "$name")"
  else
    printf '\nDefined in %s\n' "${_OPMEXEC_DIRECTIVE_FILE[$name]}"
  fi
}

# A command that opens the man page, at directive @NAME's section if given:
# man opmexec when man finds the page, else man with the page's path. less
# (man's usual pager) gets a search for the section's heading in LESS; other
# pagers ignore it. ("$" would end the option in LESS: the heading's indent of
# three spaces is what tells it from other mentions.)
opmexec::man_command() {
  local name="${1:-}" page=opmexec
  man -w opmexec > /dev/null 2>&1 || page="$OPMEXEC_HOME/man/man1/opmexec.1"
  if [[ -n "$name" ]]; then
    printf "LESS='+/^   @%s' man %q\n" "$name" "$page"
  else
    printf 'man %q\n' "$page"
  fi
}

# Print "SPEC<TAB>DESCRIPTION" rows in two columns, the first WIDTH wide; a
# longer SPEC gets its description on the next line
opmexec::print_rows() {
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
# Usage: opmexec::unknown_option NAME OPTION [HINT]; returns 1
opmexec::unknown_option() {
  opmexec::error "@$1: unknown option: $2 (@help @$1 shows the options${3:+; $3})"
  return 1
}

# --- Workflow setup ------------------------------------------------------------

# Apply one workflow option (the options of the opmexec command that are not
# about how to run it). Sets _OPMEXEC_SHIFT to the number of arguments used,
# 0 if $1 is not a workflow option; returns 1 on errors.
opmexec::setup_option() {
  _OPMEXEC_SHIFT=0

  # Settings registered by directives (opmexec::directive_setting)
  if [[ "$1" == --* && -n "${_OPMEXEC_SETTING_VAR[${1#--}]:-}" ]]; then
    if [[ $# -lt 2 ]]; then
      opmexec::error "Option $1 needs a value"
      return 1
    fi
    export "${_OPMEXEC_SETTING_VAR[${1#--}]}=$2"
    _OPMEXEC_SHIFT=2
    return 0
  fi

  case "$1" in
    -n|--np|-q|--queue|-s|--scheduler|--depends-on|--*-options|--directives)
      if [[ $# -lt 2 ]]; then
        opmexec::error "Option $1 needs a value"
        return 1
      fi
      ;;
  esac

  case "$1" in
    -n|--np) export OPMEXEC_NP="$2" ;;
    -q|--queue) export OPMEXEC_QUEUE="$2" ;;
    -s|--scheduler) export OPMEXEC_SCHEDULER="$2" ;;
    --depends-on)
      if [[ -z "${2//[ ,]/}" ]]; then
        opmexec::error "--depends-on needs a job ID (got: '$2')"
        return 1
      fi
      export OPMEXEC_DEPENDS_ON="${OPMEXEC_DEPENDS_ON:+$OPMEXEC_DEPENDS_ON,}$2"
      ;;
    --directives)
      opmexec::use "$2" || return 1
      ;;
    --*-options)
      # --<scheduler>-options (native options for that scheduler's jobs) or
      # --<directive>-options (options for every invocation of the directive),
      # added to the configuration's OPMEXEC_<NAME>_OPTIONS and exported so
      # that directives running inside jobs get them too
      local name=${1#--} var
      name=${name%-options}
      if [[ -z "${_OPMEXEC_DIRECTIVE_OPTIONS[$name]:-}" ]]; then
        if [[ -n "${_OPMEXEC_DIRECTIVE_KIND[$name]:-}" ]]; then
          opmexec::error "Unknown option: $1 (@$name takes no options)"
          return 1
        fi
        opmexec::options_scheduler "$1" > /dev/null || {
          opmexec::error "Directive options exist for: $(opmexec::directives_with_options)"
          return 1
        }
      fi
      var=$(opmexec::options_var "$name")
      export "$var=${!var:+${!var} }$2"
      ;;
    --dry-run)
      export OPMEXEC_DRY_RUN=true
      _OPMEXEC_SHIFT=1
      return 0
      ;;
    *)
      return 0
      ;;
  esac
  _OPMEXEC_SHIFT=2
}

# Configure the workflow with the same options as the opmexec command, e.g.
#   opmexec::setup -s localq -n 8 --slurm-options "--time=1:00:00" --dry-run
# and turn on workflow mode (see opmexec::workflow_mode), except in
# interactive shells
opmexec::setup() {
  while [[ $# -gt 0 ]]; do
    opmexec::setup_option "$@" || return 1
    if [[ "$_OPMEXEC_SHIFT" -eq 0 ]]; then
      opmexec::error "opmexec::setup: unknown option: $1"
      return 1
    fi
    shift "$_OPMEXEC_SHIFT"
  done
  [[ $- == *i* ]] || opmexec::workflow_mode
}

# Workflow mode: forget this run's job list on exit (also on HUP/INT/PIPE/TERM;
# jobs already submitted keep running), and stop the workflow on an unknown
# directive. On for opmexec and for scripts that source the library; not for
# interactive shells, whose traps it would take over.
opmexec::workflow_mode() {
  [[ -z "${_OPMEXEC_WORKFLOW_MODE:-}" ]] || return 0
  _OPMEXEC_WORKFLOW_MODE=true
  OPMEXEC_WORKFLOW_PID=$$

  trap 'opmexec::workflow_exit' EXIT
  trap 'opmexec::workflow_signal HUP 129' HUP
  trap 'opmexec::workflow_signal INT 130' INT
  trap 'opmexec::workflow_signal PIPE 141' PIPE
  trap 'opmexec::workflow_signal TERM 143' TERM
  trap 'exit 127' USR1  # sent by command_not_found_handle

  # A signal ignored when bash started cannot be trapped (bash keeps it
  # ignored, e.g. HUP under nohup): the workflow then does not stop on it
  if [[ "${OPMEXEC_DEBUG:-}" == true ]]; then
    local sig
    for sig in HUP INT PIPE TERM; do
      [[ "$(trap -p "$sig")" == *workflow_signal* ]] ||
        opmexec::debug "SIG$sig was ignored when this shell started: the workflow ignores it too"
    done
  fi
}

# A trapped signal in workflow mode: exit with STATUS (128 + its number), which
# runs the exit handler. Usage: opmexec::workflow_signal NAME STATUS
opmexec::workflow_signal() {
  opmexec::debug "SIG$1 received: exiting with status $2"
  exit "$2"
}

# Exit handler of workflow mode: the standard clean-up idiom. Further signals
# are ignored, so that nothing interrupts the clean-up: they often come in
# twos (timeout signals the command, then its process group; a closing
# terminal, every process), and the commands it runs (rm) inherit that. What
# a signal that cannot be handled (kill -9) leaves behind is harmless: each
# run reads only its own session file, and the next opmexec on this host
# removes those of ended runs (see the top).
opmexec::workflow_exit() {
  local rc=$? njobs=0
  trap '' HUP INT PIPE TERM

  # The count is only printed in dry runs (counting forks)
  opmexec::dry_run && njobs=$(( $(opmexec::session_jobs | wc -l) ))  # BSD wc pads with spaces
  # Remove first: printing can fail (e.g. closed pipe) and end the handler
  if rm -f "$OPMEXEC_SESSION_FILE" "$OPMEXEC_SESSION_FILE.reported"; then
    opmexec::debug "Exit handler (status $rc): removed ${OPMEXEC_SESSION_FILE##*/}"
  else
    opmexec::debug "Exit handler (status $rc): could not remove ${OPMEXEC_SESSION_FILE##*/}"
  fi

  if opmexec::dry_run && [[ $rc -eq 0 ]]; then
    opmexec::dry "done: $njobs job(s) would be submitted; nothing was submitted"
  elif opmexec::dry_run; then
    opmexec::dry "stopped (exit status $rc) after $njobs job(s); nothing was submitted"
  fi
}

# --- Unknown directives ----------------------------------------------------------

# Keep any existing handler (e.g. a distro's command-not-found) for other commands
if declare -f command_not_found_handle >/dev/null && ! declare -f opmexec::prev_command_not_found_handle >/dev/null; then
  eval "$(declare -f command_not_found_handle | sed '1s/command_not_found_handle/opmexec::prev_command_not_found_handle/')"
fi

# Unknown @directive: clear error, and in workflow mode stop the workflow.
# Bash runs this handler in a subshell, so it signals the workflow's process
# (OPMEXEC_WORKFLOW_PID) instead of exiting.
command_not_found_handle() {
  if [[ "$1" != @* ]]; then
    if declare -f opmexec::prev_command_not_found_handle >/dev/null; then
      opmexec::prev_command_not_found_handle "$@"
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

  opmexec::error "Unknown directive: $1${suggestion:+ (did you mean $suggestion?)}"
  [[ -n "${OPMEXEC_WORKFLOW_PID:-}" ]] && kill -USR1 "$OPMEXEC_WORKFLOW_PID" 2>/dev/null
  return 127
}

# --- Startup -------------------------------------------------------------------------

opmexec::ensure_state_dirs

opmexec::load_modules "$OPMEXEC_HOME/lib/directives" core
opmexec::load_modules "$OPMEXEC_HOME/lib/extensions" extension
IFS=: read -r -a _OPMEXEC_PATHS <<< "${OPMEXEC_DIRECTIVE_PATH:-}"
for _OPMEXEC_PATH in "${_OPMEXEC_PATHS[@]}"; do
  if [[ -e "$_OPMEXEC_PATH" ]]; then
    opmexec::load_modules "$_OPMEXEC_PATH" extension
  elif [[ -n "$_OPMEXEC_PATH" ]]; then
    opmexec::debug "Directive path not found, skipped: $_OPMEXEC_PATH"
  fi
done
unset _OPMEXEC_PATHS _OPMEXEC_PATH

_OPMEXEC_LOADED=true

# Scripts that source the library get workflow mode; the opmexec command turns
# it on itself, and interactive shells get the interactive features instead
if [[ $- == *i* ]]; then
  source "$OPMEXEC_HOME/lib/interactive.sh"
elif [[ -z "${_OPMEXEC_CLI:-}" ]]; then
  opmexec::workflow_mode
fi
