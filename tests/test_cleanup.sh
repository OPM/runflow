#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Session cleanup on exit and signals; submitted jobs survive runflow

test_session_removed_on_normal_exit() {
  run "$RUNFLOW" -c @wait @submit true
  assert_rc 0
  assert_eq "$(session_files)" 0
}

no_session_files() {
  [[ "$(session_files)" == 0 ]]
}

test_tests_start_with_default_signals() {
  # As from a terminal (the runner resets them): a signal ignored from the
  # start cannot be trapped, and the signal tests would mean nothing
  local ignored
  ignored=$(bash -c 'trap -p' | grep -E "^trap -- '' SIG(INT|QUIT|HUP|TERM|PIPE)$")
  [[ -z "$ignored" ]] || fail "the test started with: $ignored"
}

test_session_removed_on_signals() {
  cat > workflow.sh << 'EOF'
@submit sleep 5 > /dev/null
@wait
EOF
  local sig rc
  for sig in INT TERM HUP; do
    RUNFLOW_DEBUG=true timeout -s "$sig" 1.5 "$RUNFLOW" workflow.sh > "$sig.log" 2>&1
    rc=$?
    # The handler may still be finishing when timeout returns. On failure,
    # what is needed to tell why: timeout's exit status (124: runflow ended
    # after the signal), runflow's processes left, and its debug output
    wait_for 10 no_session_files ||
      fail "session file left after $sig (timeout exit status $rc; processes left:
$(ps -eo pid,pgid,stat,args | grep -F "$SANDBOX" | grep -v grep)
--- runflow's output:
$(cat "$sig.log")"
  done
}

test_second_signal_does_not_stop_the_cleanup() {
  # Two HUPs to runflow's process group, as timeout and closing terminals
  # send them: the second arrives while the exit handler removes the session
  # file, and must stop neither the handler nor the rm it runs. The workflow
  # makes rm slow: a sleep first, which a signal it did not ignore would end,
  # and rm with it. (A second signal while the first is being handled, before
  # the exit handler starts, cannot be timed from here: workflow_signal
  # ignores signals from its first command for that.)
  require_cmd perl
  cat > workflow.sh << 'WORKFLOW'
rm() { sleep 1 && command rm "$@"; }
@submit true > /dev/null
echo started > started
sleep 30 &
wait
WORKFLOW
  local pid rc
  RUNFLOW_DEBUG=true perl -e 'setpgrp(0, 0); exec @ARGV' "$RUNFLOW" workflow.sh > out.log 2>&1 &
  pid=$!
  wait_for 10 test -f started || fail "the workflow did not start"
  kill -HUP -- "-$pid"
  sleep 0.3
  kill -HUP -- "-$pid"
  wait "$pid"
  rc=$?
  assert_eq "$rc" 129
  assert_file_contains out.log "SIGHUP received: exiting with status 129"
  assert_file_contains out.log "Exit handler (status 129): removed session."
  assert_eq "$(session_files)" 0
}

test_signal_during_a_normal_exit_does_not_stop_the_cleanup() {
  # The same, when the workflow ended by itself: a HUP to its process group
  # while the exit handler runs rm
  require_cmd perl
  cat > workflow.sh << 'WORKFLOW'
rm() { echo > in-rm; sleep 1 && command rm "$@"; }
@submit true > /dev/null
WORKFLOW
  local pid rc
  RUNFLOW_DEBUG=true perl -e 'setpgrp(0, 0); exec @ARGV' "$RUNFLOW" workflow.sh > out.log 2>&1 &
  pid=$!
  wait_for 10 test -f in-rm || fail "the exit handler did not start"
  kill -HUP -- "-$pid"
  wait "$pid"
  rc=$?
  assert_eq "$rc" 0
  assert_file_contains out.log "Exit handler (status 0): removed session."
  assert_eq "$(session_files)" 0
}

test_session_file_of_an_ended_run_is_removed() {
  # Left by a run that could not clean up (kill -9): removed by the next
  # runflow on the same host, whose process is gone
  local state="$HOME/.local/state/runflow" pid
  mkdir -p "$state"
  sh -c 'exit 0' & pid=$!
  wait "$pid"
  echo localq:1 > "$state/session.${HOSTNAME%%.*}.$pid"
  echo localq:1 > "$state/session.otherhost.$pid"   # another host's: kept
  run "$RUNFLOW" -c true
  assert_rc 0
  [[ ! -e "$state/session.${HOSTNAME%%.*}.$pid" ]] || fail "the ended run's session file is left"
  [[ -e "$state/session.otherhost.$pid" ]] || fail "another host's session file was removed"
}

test_session_removed_on_closed_pipe() {
  "$RUNFLOW" --dry-run -c @wait @submit true 2>&1 | head -1 > /dev/null
  assert_eq "$(session_files)" 0
}

test_submitted_jobs_survive_runflow_kill() {
  cat > workflow.sh << 'EOF'
@submit -o "$PWD/out.log" sh -c 'sleep 1.5; echo survived' > /dev/null
@wait
EOF
  timeout -s TERM 0.8 "$RUNFLOW" workflow.sh > /dev/null 2>&1
  wait_for 10 grep -q survived out.log 2> /dev/null || fail "job did not finish after runflow was killed"
}
