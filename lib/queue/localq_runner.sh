#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# localq job runner: waits for its turn, runs the job, records the result
# Usage: localq_runner.sh JOBDIR command [args...]  (started by runflow::backend_submit_job)

source "$(dirname "${BASH_SOURCE[0]}")/../common.sh" || exit 1
source "$(dirname "${BASH_SOURCE[0]}")/localq.sh"

dir="$1"
shift
id=${dir##*/}

# Wait until the job may start. Reaping dead runners is the expensive part of
# a scheduling check (it visits every active job), so do it every few seconds
# only; a dead job holds its slots at most that long.
last_reap=0
while true; do
  {
    flock 9
    runflow::localq::now now
    if (( now - last_reap >= ${RUNFLOW_LOCALQ_REAP_INTERVAL:-5} )); then
      runflow::localq::reap
      last_reap=$now
    fi
    runflow::localq::try_start "$id"
    rc=$?
  } 9>"$RUNFLOW_LOCALQ_DIR/lock"

  case "$rc" in
    0) break ;;
    2) exit 1 ;;
  esac
  sleep "${RUNFLOW_LOCALQ_POLL:-1}"
done

runflow::localq::read output "$dir" output
runflow::localq::read limit "$dir" time_limit
runflow::localq::read niceness "$dir" nice
[[ -z "$niceness" ]] || set -- nice -n "$niceness" "$@"

# Time limit: a watchdog ends the job as a cancellation would (the whole
# process group, this runner included) and records it as FAILED. It does not
# hold running.lock, so waiters wake up when the runner dies.
watchdog=""
if (( ${limit:-0} > 0 )); then
  (
    exec 8>&-
    sleeper=""
    trap '[[ -z "$sleeper" ]] || kill "$sleeper" 2> /dev/null; exit 0' TERM
    sleep "$limit" &
    sleeper=$!
    wait "$sleeper"
    trap '' TERM
    {
      flock 9
      runflow::localq::read status "$dir" status
      if [[ "$status" == RUNNING ]]; then
        echo "localq: job $id reached its time limit ($(runflow::localq::duration "$limit")) and was stopped" >> "$output"
        runflow::localq::finish "$dir" FAILED
        kill -TERM -- "-$$" 2> /dev/null
      fi
    } 9>"$RUNFLOW_LOCALQ_DIR/lock"
  ) &
  watchdog=$!
fi

# fd 8 holds running.lock (see runflow::backend_submit_job); the job does not need it
"$@" > "$output" 2>&1 8>&-
rc=$?
[[ -z "$watchdog" ]] || kill "$watchdog" 2> /dev/null

{
  flock 9
  runflow::localq::read status "$dir" status
  if [[ "$status" != RUNNING ]]; then
    :  # already final: stopped by the time limit or cancelled
  elif [[ "$rc" -eq 0 ]]; then
    runflow::localq::finish "$dir" COMPLETED "$rc"
  else
    runflow::localq::finish "$dir" FAILED "$rc"
  fi
} 9>"$RUNFLOW_LOCALQ_DIR/lock"
