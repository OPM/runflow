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
