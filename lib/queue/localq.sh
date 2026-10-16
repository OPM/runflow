#!/usr/bin/env bash
# localq - slim local scheduler (single host, per user)
#
# Each job runs as a detached process group whose runner (localq_runner.sh)
# schedules itself under a lock: FIFO among jobs whose dependency is met,
# limited to OPMEXEC_LOCALQ_SLOTS slots (default: number of CPUs). No daemon is needed.
#
# State per job in $OPMEXEC_LOCALQ_DIR/<id>/: np queue depends_on output cmd status
# exitcode pid pstart submit_time start_time end_time running.lock, and the
# native options time_limit nice name exclusive. Active
# (PENDING/RUNNING) jobs are listed in $OPMEXEC_LOCALQ_DIR/active/.
# Statuses: PENDING RUNNING COMPLETED FAILED CANCELLED.
#
# Waiting without polling: each runner holds an exclusive lock on its job's
# running.lock for its whole life; the kernel releases it when the runner
# exits (even on kill -9), which wakes up waiters blocked on a shared lock.
#
# Linux and macOS (with Homebrew's flock); see opmexec::backend_check_requirements.

# State on a local disk, per user and machine: locks behave as designed (on
# NFS, flock is emulated with process-owned locks, which breaks the inherited
# running.lock) and the scheduling path stays fast. A fixed path, not session
# variables such as XDG_RUNTIME_DIR or TMPDIR, so that every shell, cron job
# and runner of the user finds the same queue; /var/tmp survives reboots.
# OPMEXEC_LOCALQ_DIR overrides it, e.g. one queue per pilot job.
OPMEXEC_LOCALQ_DIR="${OPMEXEC_LOCALQ_DIR:-/var/tmp/opmexec-$UID/localq}"

# One word of a command saved with printf %q (for job listings)
OPMEXEC_LOCALQ_TOKEN="(\\\$'([^'\\\\]|\\\\.)*'|([^ \\\\]|\\\\.)+)"
OPMEXEC_LOCALQ_RUNNER="$(dirname "${BASH_SOURCE[0]}")/localq_runner.sh"

# Tools localq needs beyond bash; flock is not part of macOS
opmexec::backend_check_requirements() {
  local missing=() cmd

  for cmd in flock getconf ps nohup; do
    command -v "$cmd" > /dev/null || missing+=("$cmd")
  done
  if ! command -v setsid > /dev/null && ! command -v perl > /dev/null; then
    missing+=("setsid (or perl)")
  fi

  if [[ ${#missing[@]} -gt 0 ]]; then
    opmexec::error "localq needs these commands, which were not found: ${missing[*]}"
    opmexec::install_hint flock
    return 1
  fi
  
  opmexec::localq::state_dir
}

# Create the state directory, private to the user. In a shared directory such
# as /var/tmp another user could create it first or plant a symlink there, so
# refuse a directory that is not the user's own: the default's
# /var/tmp/opmexec-<uid>, and the state directory itself.
opmexec::localq::state_dir() {
  local path
  
  ( umask 077; mkdir -p "$OPMEXEC_LOCALQ_DIR/active" ) 2> /dev/null
  for path in "/var/tmp/opmexec-$UID" "$OPMEXEC_LOCALQ_DIR"; do
    [[ "$path" == "$OPMEXEC_LOCALQ_DIR" || "$OPMEXEC_LOCALQ_DIR" == "$path"/* ]] || continue
    if [[ -L "$path" || ! -d "$path" || ! -O "$path" ]]; then
      opmexec::error "localq: $path is not a directory owned by you; not using it (see OPMEXEC_LOCALQ_DIR)"
      return 1
    fi
    chmod 700 "$path" 2> /dev/null
  done
}

# Helpers on the scheduling path avoid forking (no cat/ls/date/$(...)): every
# waiting runner scans all active jobs under the queue lock, so a fork per
# field would make the lock the bottleneck as the queue grows.

# Number of slots, into variable VAR (cached in this shell: getconf forks)
opmexec::localq::slots() {
  [[ -n "${_OPMEXEC_LOCALQ_SLOTS_CACHE:-}" ]] || _OPMEXEC_LOCALQ_SLOTS_CACHE="${OPMEXEC_LOCALQ_SLOTS:-$(getconf _NPROCESSORS_ONLN)}"
  printf -v "$1" '%s' "$_OPMEXEC_LOCALQ_SLOTS_CACHE"
}

# Current time in seconds, into variable VAR
opmexec::localq::now() {
  printf -v "$1" '%(%s)T' -1
}

# Write a job field atomically
opmexec::localq::set() {
  local dir="$1" key="$2" value="$3"
  printf '%s\n' "$value" > "$dir/$key.tmp" && mv "$dir/$key.tmp" "$dir/$key"
}

# Read a job field into variable VAR (empty if missing): opmexec::localq::read VAR DIR KEY
opmexec::localq::read() {
  local _line=""
  { IFS= read -r _line || true; } 2> /dev/null < "$2/$3"
  printf -v "$1" '%s' "$_line"
}

# Print a job field (for code off the scheduling path)
opmexec::localq::get() {
  local _value
  opmexec::localq::read _value "$1" "$2"
  [[ -z "$_value" ]] || echo "$_value"
}

# Process start time into variable VAR; empty if not running.
# Linux: clock ticks since boot from /proc (no fork). Elsewhere (macOS): ps
# start time (1 s resolution; forks, which is why runners reap only every few
# seconds).
if [[ -d /proc/self ]]; then
  opmexec::localq::pstart_into() {
    local _stat="" _fields
    { read -r _stat || true; } 2> /dev/null < "/proc/$2/stat"
    _fields=(${_stat##*) })
    printf -v "$1" '%s' "${_fields[19]:-}"
  }
else
  opmexec::localq::pstart_into() {
    local _start
    _start=$(ps -o lstart= -p "$2" 2> /dev/null)
    printf -v "$1" '%s' "${_start// /_}"
  }
fi

opmexec::localq::pstart() {
  local _start
  opmexec::localq::pstart_into _start "$1"
  echo "$_start"
}

# Run a command in a new session, keeping its pid (for $!). setsid is not
# part of macOS; perl (which is) does the same.
opmexec::localq::detach() {
  if command -v setsid > /dev/null; then
    exec setsid "$@"
  fi
  exec perl -MPOSIX -e 'POSIX::setsid() or die "setsid: $!\n"; exec { $ARGV[0] } @ARGV or die "exec: $!\n"' "$@"
}

# Is the job's runner alive? (start time guards against pid reuse)
opmexec::localq::alive() {
  local pid pstart now
  opmexec::localq::read pid "$1" pid
  [[ -n "$pid" ]] || return 1
  opmexec::localq::read pstart "$1" pstart
  opmexec::localq::pstart_into now "$pid"
  [[ -n "$now" && "$now" == "$pstart" ]]
}

# Record a final status (caller holds the lock)
opmexec::localq::finish() {
  local dir="$1" status="$2" exitcode="${3:-}" now
  [[ -n "$exitcode" ]] && opmexec::localq::set "$dir" exitcode "$exitcode"
  opmexec::localq::now now
  opmexec::localq::set "$dir" end_time "$now"
  opmexec::localq::set "$dir" status "$status"
  rm -f "$OPMEXEC_LOCALQ_DIR/active/${dir##*/}"
}

# Mark active jobs whose runner died as FAILED (caller holds the lock)
opmexec::localq::reap() {
  local f
  for f in "$OPMEXEC_LOCALQ_DIR"/active/*; do
    [[ -e "$f" ]] || continue
    opmexec::localq::alive "$OPMEXEC_LOCALQ_DIR/${f##*/}" || opmexec::localq::finish "$OPMEXEC_LOCALQ_DIR/${f##*/}" FAILED
  done
}

# Slots a running job uses, into variable VAR: its np, or every slot if it
# is exclusive.  Usage: opmexec::localq::need VAR DIR SLOTS
opmexec::localq::need() {
  local _np _exclusive
  opmexec::localq::read _exclusive "$2" exclusive
  if [[ -n "$_exclusive" ]]; then
    printf -v "$1" '%s' "$3"
  else
    opmexec::localq::read _np "$2" np
    printf -v "$1" '%s' "${_np:-0}"
  fi
}

# Dependency state of a job (all dependencies must complete), into variable
# VAR: ok | wait | failed.  Usage: opmexec::localq::dep_state VAR DIR
opmexec::localq::dep_state() {
  local _deps _dep _status _state=ok
  opmexec::localq::read _deps "$2" depends_on
  
  for _dep in ${_deps//,/ }; do
    opmexec::localq::read _status "$OPMEXEC_LOCALQ_DIR/$_dep" status
    case "$_status" in
      COMPLETED) ;;
      PENDING|RUNNING) _state=wait ;;
      *) _state=failed; break ;;
    esac
  done
  
  printf -v "$1" '%s' "$_state"
}

# Try to start a job (caller holds the lock).
# Returns 0 if started, 1 if it must wait, 2 if it can never run.
opmexec::localq::try_start() {
  local id="$1" dir="$OPMEXEC_LOCALQ_DIR/$1"
  local np slots used=0 f other odir status onp dep now
  
  opmexec::localq::dep_state dep "$dir"
  case "$dep" in
    failed) opmexec::localq::finish "$dir" FAILED; return 2 ;;
    wait) return 1 ;;
  esac
  
  opmexec::localq::slots slots
  opmexec::localq::need np "$dir" "$slots"
  
  for f in "$OPMEXEC_LOCALQ_DIR"/active/*; do
    [[ -e "$f" ]] || continue
    other=${f##*/}
    odir="$OPMEXEC_LOCALQ_DIR/$other"
    opmexec::localq::read status "$odir" status
    case "$status" in
      RUNNING)
        opmexec::localq::need onp "$odir" "$slots"
        used=$((used + onp))
        ;;
      PENDING)
        # FIFO: an older job that is ready to run goes first
        if (( other < id )); then
          opmexec::localq::dep_state dep "$odir"
          [[ "$dep" == ok ]] && return 1
        fi
        ;;
    esac
  done
  
  if (( used + np <= slots )); then
    opmexec::localq::now now
    opmexec::localq::set "$dir" start_time "$now"
    opmexec::localq::set "$dir" status RUNNING
    return 0
  fi
  return 1
}

# Time limit in seconds, as SLURM writes it: MINUTES, MINUTES:SECONDS,
# HOURS:MINUTES:SECONDS, DAYS-HOURS, DAYS-HOURS:MINUTES, DAYS-HOURS:MINUTES:SECONDS.
# Returns 1 for anything else.
opmexec::localq::time_seconds() {
  local value="$1" days=0 parts
  [[ "$value" =~ ^([0-9]+-)?[0-9]+(:[0-9]+){0,2}$ ]] || return 1
  if [[ "$value" == *-* ]]; then
    days=${value%%-*}
    IFS=: read -ra parts <<< "${value#*-}"
    echo $(( ((10#$days * 24 + 10#${parts[0]}) * 60 + 10#${parts[1]:-0}) * 60 + 10#${parts[2]:-0} ))
  else
    IFS=: read -ra parts <<< "$value"
    case ${#parts[@]} in
      1) echo $(( 10#${parts[0]} * 60 )) ;;
      2) echo $(( 10#${parts[0]} * 60 + 10#${parts[1]} )) ;;
      3) echo $(( (10#${parts[0]} * 60 + 10#${parts[1]}) * 60 + 10#${parts[2]} )) ;;
    esac
  fi
}

# Native options (--localq-options), spelled as in SLURM, into the variables
# limit (seconds), niceness, name and exclusive of the caller
opmexec::localq::parse_options() {
  local word value words i=0
  local supported="supported: --time, --nice, --job-name, --exclusive"
  opmexec::split_options "$1" --localq-options || return 1
  words=("${_OPMEXEC_WORDS[@]}")

  while (( i < ${#words[@]} )); do
    word=${words[i]}
    i=$((i + 1))
    case "$word" in
      --time=*|--nice=*|--job-name=*)
        value=${word#*=}
        word=${word%%=*}
        ;;
      --time|--job-name)
        if (( i >= ${#words[@]} )); then
          opmexec::error "localq: $word needs a value"
          return 1
        fi
        value=${words[i]}
        i=$((i + 1))
        ;;
      --nice|--exclusive) value="" ;;
      *)
        opmexec::error "localq: unknown option $word ($supported)"
        return 1
        ;;
    esac

    case "$word" in
      --time)
        limit=$(opmexec::localq::time_seconds "$value") || {
          opmexec::error "localq: invalid --time: $value (MINUTES, MM:SS, HH:MM:SS or DAYS-HH[:MM[:SS]])"
          return 1
        }
        ;;
      --nice)
        niceness=${value:-10}
        if ! [[ "$niceness" =~ ^[0-9]+$ ]] || (( 10#$niceness > 19 )); then
          opmexec::error "localq: --nice must be 0..19 (got: $value)"
          return 1
        fi
        niceness=$((10#$niceness))
        ;;
      --job-name) name=$value ;;
      --exclusive) exclusive=true ;;
    esac
  done
}

# Submit job to localq
opmexec::backend_submit_job() {
  local queue="$1" np="$2" output="$3" depends_on="$4" options="$5"
  shift 5
  local slots id dir now limit="" niceness="" name="" exclusive=""

  opmexec::localq::parse_options "$options" || return 1

  opmexec::localq::slots slots
  if ! [[ "$np" =~ ^[1-9][0-9]*$ ]] || (( np > slots )); then
    opmexec::error "localq: number of processes must be 1..$slots (got: $np)"
    return 1
  fi

  local dep
  for dep in ${depends_on//,/ }; do
    if [[ ! "$dep" =~ ^[0-9]+$ || ! -f "$OPMEXEC_LOCALQ_DIR/$dep/status" ]]; then
      opmexec::error "localq: unknown dependency job: $dep"
      return 1
    fi
  done

  mkdir -p "$OPMEXEC_LOCALQ_DIR/active" || return 1

  {
    flock 9
    opmexec::localq::read id "$OPMEXEC_LOCALQ_DIR" counter
    id=$(( ${id:-0} + 1 ))
    echo "$id" > "$OPMEXEC_LOCALQ_DIR/counter"
    
    # Not visible to other jobs until its active marker exists: write the
    # fields directly (no temporary file + mv per field)
    dir="$OPMEXEC_LOCALQ_DIR/$id"
    mkdir "$dir" || return 1
    opmexec::localq::now now
    printf '%s\n' "$np" > "$dir/np"
    printf '%s\n' "$queue" > "$dir/queue"
    printf '%s\n' "$depends_on" > "$dir/depends_on"
    printf '%s\n' "${output:-${OPMEXEC_LOG_DIR}/localq.${HOSTNAME%%.*}.$id.log}" > "$dir/output"
    printf '%q ' "$@" > "$dir/cmd"
    printf '\n' >> "$dir/cmd"
    printf '%s\n' "$now" > "$dir/submit_time"
    printf '%s\n' "$limit" > "$dir/time_limit"
    printf '%s\n' "$niceness" > "$dir/nice"
    printf '%s\n' "$name" > "$dir/name"
    printf '%s\n' "$exclusive" > "$dir/exclusive"
    printf '%s\n' PENDING > "$dir/status"
    : > "$OPMEXEC_LOCALQ_DIR/active/$id"

    # Detached runner in its own session; must not inherit the queue lock
    # (fd 9). It inherits fd 8, already holding running.lock exclusively, so
    # waiters cannot get in before the runner starts. Launched from a subshell
    # so $! is the runner even with job control on; "$BASH" is the bash 4+
    # running now (on macOS, /bin/bash is 3.2).
    (
      exec 8> "$dir/running.lock"
      flock -x 8
      opmexec::localq::detach nohup "$BASH" "$OPMEXEC_LOCALQ_RUNNER" "$dir" "$@" </dev/null >/dev/null 2>&1 9>&- &
      echo "$!" > "$dir/pid"
    )
    opmexec::localq::set "$dir" pstart "$(opmexec::localq::pstart "$(opmexec::localq::get "$dir" pid)")"
  } 9>"$OPMEXEC_LOCALQ_DIR/lock"

  echo "$id"
}

# Block until a job is final and print its status, without polling: sleep on
# a shared lock of running.lock until the runner exits, then re-check (which
# also covers spurious wake-ups and runners that died).
# Usage: opmexec::backend_wait_job JOBID [TIMEOUT]  (seconds, 0 = none)
# Returns 2 on timeout, 1 (and UNKNOWN) for an unknown job.
opmexec::backend_wait_job() {
  local id="$1" timeout="${2:-0}" dir="$OPMEXEC_LOCALQ_DIR/$1" status deadline=0 left
  (( timeout > 0 )) && deadline=$(( $(date +%s) + timeout ))

  while true; do
    status=$(opmexec::backend_job_status "$id") || { echo "$status"; return 1; }
    case "$status" in
      PENDING|RUNNING) ;;
      *) echo "$status"; return 0 ;;
    esac

    if (( deadline > 0 )); then
      left=$(( deadline - $(date +%s) ))
      (( left > 0 )) || return 2
    fi

    if (( deadline > 0 )); then
      flock -s -w "$left" "$dir/running.lock" true
    else
      flock -s "$dir/running.lock" true
    fi
  done
}

# Get job status: PENDING RUNNING COMPLETED FAILED CANCELLED (UNKNOWN if missing)
opmexec::backend_job_status() {
  local id="$1" dir="$OPMEXEC_LOCALQ_DIR/$1"

  if [[ ! -f "$dir/status" ]]; then
    opmexec::error "localq: unknown job: $id"
    echo UNKNOWN
    return 1
  fi

  { flock 9; opmexec::localq::reap; } 9>"$OPMEXEC_LOCALQ_DIR/lock"
  opmexec::localq::get "$dir" status
}

# Cancel a pending or running job (kills its process group)
opmexec::backend_cancel_job() {
  local id="$1" dir="$OPMEXEC_LOCALQ_DIR/$1"

  {
    flock 9
    case "$(opmexec::localq::get "$dir" status)" in
      PENDING|RUNNING)
        opmexec::localq::alive "$dir" && kill -TERM -- "-$(opmexec::localq::get "$dir" pid)" 2>/dev/null
        opmexec::localq::finish "$dir" CANCELLED
        ;;
      "")
        opmexec::error "localq: unknown job: $id"
        return 1
        ;;
      *)
        opmexec::error "localq: job $id is not pending or running"
        return 1
        ;;
    esac
  } 9>"$OPMEXEC_LOCALQ_DIR/lock"
}

# Format seconds as H:MM:SS
opmexec::localq::duration() {
  printf '%d:%02d:%02d' $(($1 / 3600)) $(($1 % 3600 / 60)) $(($1 % 60))
}

# List jobs: pending/running, or every job with "all"
opmexec::backend_list_jobs() {
  local mode="${1:-active}"
  local id dir status np queue name depends_on exitcode start end elapsed cmd used=0 ids slots need
  
  mkdir -p "$OPMEXEC_LOCALQ_DIR/active" || return 1
  { flock 9; opmexec::localq::reap; } 9>"$OPMEXEC_LOCALQ_DIR/lock"
  
  opmexec::localq::slots slots
  for id in $(ls "$OPMEXEC_LOCALQ_DIR/active"); do
    dir="$OPMEXEC_LOCALQ_DIR/$id"
    [[ "$(opmexec::localq::get "$dir" status)" == RUNNING ]] || continue
    opmexec::localq::need need "$dir" "$slots"
    used=$((used + need))
  done
  
  if [[ "$mode" == all ]]; then
    ids=$(ls "$OPMEXEC_LOCALQ_DIR" | grep -E '^[0-9]+$' | sort -n)
  else
    ids=$(ls "$OPMEXEC_LOCALQ_DIR/active" | sort -n)
  fi
  
  echo "localq: slots $used/$slots in use"
  
  if [[ -z "$ids" ]]; then
    # Finished jobs are only listed with --jobs=all: say they exist
    local finished=0 dir
    if [[ "$mode" != all ]]; then
      for dir in "$OPMEXEC_LOCALQ_DIR"/[0-9]*; do
        [[ -d "$dir" ]] && finished=$((finished + 1))
      done
    fi
    if (( finished > 0 )); then
      echo "(no active jobs; $finished finished, see --jobs=all)"
    else
      echo "(no jobs)"
    fi
    return 0
  fi
  
  printf '%-6s %-9s %4s %-8s %-10s %-7s %4s %9s  %s\n' ID STATUS NP QUEUE NAME DEPENDS EXIT ELAPSED COMMAND
  
  for id in $ids; do
    dir="$OPMEXEC_LOCALQ_DIR/$id"
    status=$(opmexec::localq::get "$dir" status)
    start=$(opmexec::localq::get "$dir" start_time)
    end=$(opmexec::localq::get "$dir" end_time)
    
    elapsed=-
    [[ -n "$start" ]] && elapsed=$(opmexec::localq::duration $(( ${end:-$(date +%s)} - start )))
    
    # Hide the submission wrappers (bash -c '...' opmexec-job DIR SETUP, the
    # OPMEXEC_...=value settings, opmexec -n N -c) and truncate
    cmd=$(opmexec::localq::get "$dir" cmd | sed -E "s/^bash -c $OPMEXEC_LOCALQ_TOKEN opmexec-job $OPMEXEC_LOCALQ_TOKEN $OPMEXEC_LOCALQ_TOKEN //; s/^(OPMEXEC_[A-Z0-9_]+=$OPMEXEC_LOCALQ_TOKEN? )+//; s/^[^ ]*\/opmexec -n [0-9]+ -c //; s/ $//")
    (( ${#cmd} > 60 )) && cmd="${cmd:0:57}..."
    
    opmexec::localq::read np "$dir" np
    opmexec::localq::read queue "$dir" queue
    opmexec::localq::read name "$dir" name
    (( ${#name} > 10 )) && name="${name:0:9}~"
    opmexec::localq::read depends_on "$dir" depends_on
    opmexec::localq::read exitcode "$dir" exitcode
    printf '%-6s %-9s %4s %-8s %-10s %-7s %4s %9s  %s\n' "$id" "$status" "$np" "$queue" \
      "${name:--}" "${depends_on:--}" "${exitcode:--}" "$elapsed" "$cmd"
  done
}
