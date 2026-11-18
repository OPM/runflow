#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Queue directives (@submit, @wait @submit, @wait, @cancel), job IDs and dependencies.
# Backend-agnostic: runs against TEST_SCHEDULER.

test_submit_returns_qualified_job_id() {
  local id
  id=$("$FLOWRUN" -c @submit true 2> /dev/null) || fail "submit failed"
  [[ "$id" =~ ^$TEST_SCHEDULER:[^[:space:]]+$ ]] || fail "unexpected job ID on stdout: $id"
}


test_run_waits_and_succeeds() {
  run "$FLOWRUN" -c @wait @submit -o "$PWD/out.log" sh -c 'echo done-marker'
  assert_rc 0
  assert_contains "$OUT" "completed successfully"
  assert_file_contains out.log "done-marker"
}

test_run_reports_failure() {
  run "$FLOWRUN" -c @wait @submit false
  assert_rc 1
  assert_contains "$OUT" "failed"
}

test_job_runs_in_submit_directory() {
  mkdir sub
  cd sub || fail "cd"
  run "$FLOWRUN" -c @wait @submit -o "$PWD/out.log" pwd
  assert_rc 0
  assert_eq "$(cat out.log)" "$PWD"
}

test_flow_directive_runs_inside_job() {
  run "$FLOWRUN" -c @wait @submit -n 1 -o "$PWD/out.log" @flow --x=1 A.DATA
  assert_rc 0
  assert_file_contains out.log "args=--x=1 $PWD/A.DATA np=1"
}

test_flow_directive_job_uses_job_np() {
  require_cmd mpirun
  run "$FLOWRUN" -c @wait @submit -n 2 -o "$PWD/out.log" @mpi @flow A.DATA
  assert_rc 0
  assert_eq "$(grep -c '^FLOW' out.log)" 2
}

test_submit_unknown_option_fails() {
  run "$FLOWRUN" -c @submit --dependson 1 true
  assert_rc 1
  assert_contains "$OUT" "unknown option: --dependson"
}

test_double_dash_allows_dash_command() {
  run "$FLOWRUN" -c @wait @submit -o "$PWD/out.log" -- -not-a-command
  assert_rc 1
  assert_not_contains "$OUT" "unknown option"
  assert_file_contains out.log "-not-a-command"
}

test_wait_several_jobs() {
  run_script << 'EOF'
a=$(@submit true)
b=$(@submit false)
@wait "$a" "$b"
echo "wait-rc=$?"
EOF
  assert_contains "$OUT" "completed successfully"
  assert_contains "$OUT" "failed"
  assert_contains "$OUT" "wait-rc=1"
}

test_wait_without_arguments_waits_for_session() {
  run_script << 'EOF'
@submit sh -c 'sleep 1; touch a.done' > /dev/null
@submit sh -c 'sleep 1; touch b.done' > /dev/null
@wait
echo "wait-rc=$? done=$(ls *.done | awk 'END { print NR }')"
EOF
  assert_contains "$OUT" "wait-rc=0 done=2"
}

test_wait_unknown_job_fails() {
  run "$FLOWRUN" -c @wait "$TEST_SCHEDULER:999999"
  assert_rc 1
  assert_contains "$OUT" "not found"
}

test_wait_unknown_scheduler_prefix_fails() {
  run "$FLOWRUN" -c @wait foo:1
  assert_rc 1
  assert_contains "$OUT" "unknown scheduler 'foo'"
}

test_cancel_running_job() {
  run_script << 'EOF'
j=$(@submit sleep 30)
sleep 1
@cancel "$j"
echo "cancel-rc=$?"
@wait "$j"
echo "wait-rc=$?"
EOF
  assert_contains "$OUT" "cancelled"
  assert_contains "$OUT" "cancel-rc=0"
  assert_contains "$OUT" "wait-rc=1"
}

test_cancel_finished_job_fails() {
  run_script << 'EOF'
j=$(@submit true)
@wait "$j"
@cancel "$j"
echo "cancel-rc=$?"
EOF
  assert_contains "$OUT" "cancel-rc=1"
}

test_cancel_without_arguments_cancels_session() {
  run_script << 'EOF'
@submit sleep 30 > /dev/null
@submit sleep 31 > /dev/null
sleep 1
@cancel
@wait
echo "wait-rc=$?"
EOF
  assert_eq "$(grep -c 'cancelled' <<< "$OUT")" 4  # 2 from @cancel, 2 from @wait
  assert_contains "$OUT" "wait-rc=1"
}

test_dependency_runs_after_job() {
  run_script << 'EOF'
a=$(@submit sh -c 'sleep 1; echo a >> order.txt')
b=$(@submit --depends-on "$a" sh -c 'echo b >> order.txt')
@wait "$b"
EOF
  assert_rc 0
  assert_eq "$(tr '\n' ' ' < order.txt)" "a b "
}

test_multiple_dependencies() {
  run_script << 'EOF'
a=$(@submit sh -c 'sleep 1; echo a >> order.txt')
b=$(@submit sh -c 'sleep 2; echo b >> order.txt')
c=$(@submit --depends-on "$a,$b" sh -c 'echo c >> order.txt')
@wait "$c"
EOF
  assert_rc 0
  assert_eq "$(tr '\n' ' ' < order.txt)" "a b c "
}

test_failed_dependency_fails_job() {
  run_script << 'EOF'
f=$(@submit false)
j=$(@submit --depends-on "$f" touch ran.txt)
@wait "$j"
echo "wait-rc=$?"
EOF
  assert_contains "$OUT" "wait-rc=1"
  [[ ! -e ran.txt ]] || fail "dependent job ran"
}

test_bare_dependency_id() {
  run_script << 'EOF'
a=$(@submit true)
b=$(@submit --depends-on "${a#*:}" true)
@wait "$b"
EOF
  assert_rc 0
}

test_cross_scheduler_dependency_rejected() {
  local other=localq
  [[ "$TEST_SCHEDULER" == localq ]] && other=lsf
  run "$FLOWRUN" -c @submit --depends-on "$other:1" true
  assert_rc 1
  assert_contains "$OUT" "job $other:1 cannot be a dependency of a job submitted to $TEST_SCHEDULER"
  assert_contains "$OUT" "@wait $other:1 && @submit --scheduler $TEST_SCHEDULER"
}
