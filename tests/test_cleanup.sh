#!/usr/bin/env bash
# Session cleanup on exit and signals; submitted jobs survive opmexec

test_session_removed_on_normal_exit() {
  run "$OPMEXEC" -c @wait @submit true
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
    OPMEXEC_DEBUG=true timeout -s "$sig" 1.5 "$OPMEXEC" workflow.sh > "$sig.log" 2>&1
    rc=$?
    # The handler may still be finishing when timeout returns. On failure,
    # what is needed to tell why: timeout's exit status (124: opmexec ended
    # after the signal), opmexec's processes left, and its debug output
    wait_for 10 no_session_files ||
      fail "session file left after $sig (timeout exit status $rc; processes left:
$(ps -eo pid,pgid,stat,args | grep -F "$SANDBOX" | grep -v grep)
--- opmexec's output:
$(cat "$sig.log")"
  done
}

test_second_signal_does_not_stop_the_cleanup() {
  # A second HUP while the exit handler runs (timeout and closing terminals
  # send several) must not end opmexec before it removed the session file.
  # The workflow makes its exit handler slow, so that the second signal
  # arrives in it: the first thing the handler asks is whether this is a
  # dry run.
  cat > workflow.sh << 'EOF'
opmexec::dry_run() { [[ -z "${_OPMEXEC_EXITING:-}" ]] || sleep 1; return 1; }
@submit true > /dev/null
sleep 30 &
echo "$!" > sleep.pid
echo started > started
wait
EOF
  local pid rc
  OPMEXEC_DEBUG=true "$OPMEXEC" workflow.sh > out.log 2>&1 &
  pid=$!
  wait_for 10 test -f started || fail "the workflow did not start"
  kill -HUP "$pid"
  sleep 0.3
  kill -HUP "$pid"
  wait "$pid"
  rc=$?
  kill "$(cat sleep.pid)" 2> /dev/null
  assert_eq "$rc" 129
  assert_file_contains out.log "SIGHUP received while exiting: ignored"
  assert_eq "$(session_files)" 0
}

test_session_file_of_an_ended_run_is_removed() {
  # Left by a run that could not clean up (kill -9): removed by the next
  # opmexec on the same host, whose process is gone
  local state="$HOME/.local/state/opmexec" pid
  mkdir -p "$state"
  sh -c 'exit 0' & pid=$!
  wait "$pid"
  echo localq:1 > "$state/session.${HOSTNAME%%.*}.$pid"
  echo localq:1 > "$state/session.otherhost.$pid"   # another host's: kept
  run "$OPMEXEC" -c true
  assert_rc 0
  [[ ! -e "$state/session.${HOSTNAME%%.*}.$pid" ]] || fail "the ended run's session file is left"
  [[ -e "$state/session.otherhost.$pid" ]] || fail "another host's session file was removed"
}

test_session_removed_on_closed_pipe() {
  "$OPMEXEC" --dry-run -c @wait @submit true 2>&1 | head -1 > /dev/null
  assert_eq "$(session_files)" 0
}

test_submitted_jobs_survive_opmexec_kill() {
  cat > workflow.sh << 'EOF'
@submit -o "$PWD/out.log" sh -c 'sleep 1.5; echo survived' > /dev/null
@wait
EOF
  timeout -s TERM 0.8 "$OPMEXEC" workflow.sh > /dev/null 2>&1
  wait_for 10 grep -q survived out.log 2> /dev/null || fail "job did not finish after opmexec was killed"
}
