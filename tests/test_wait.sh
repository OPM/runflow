#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# @wait: blocking without polling (localq), timeouts, and the polling fallback
# for backends without runflow::backend_wait_job

test_wait_blocks_without_polling() {
  require_localq
  # With 30 s polling, a 1 s job is still noticed as soon as it ends
  export RUNFLOW_POLL=30
  local start=$(date +%s)
  run "$RUNFLOW" -c @wait @submit sleep 1
  assert_rc 0
  (( $(date +%s) - start < 10 )) || fail "@wait took $(( $(date +%s) - start ))s: it polled instead of blocking"
}

test_wait_wakes_when_runner_is_killed() {
  require_localq
  export RUNFLOW_POLL=30
  run_script << 'EOF'
j=$(@submit sleep 30)
sleep 1
pid=$(cat "$RUNFLOW_LOCALQ_DIR/${j#*:}/pid")
( sleep 1; kill -9 "$pid" ) &
start=$(date +%s)
@wait "$j"
echo "wait-rc=$? took=$(( $(date +%s) - start ))"
kill -- "-$pid" 2> /dev/null  # orphaned children are not stopped by localq
EOF
  assert_contains "$OUT" "failed"
  assert_contains "$OUT" "wait-rc=1"
  local took
  took=$(sed -n 's/.*took=\([0-9]*\).*/\1/p' <<< "$OUT")
  (( took < 10 )) || fail "@wait took ${took}s after the runner was killed"
}

test_wait_timeout() {
  export RUNFLOW_WAIT_TIMEOUT=1
  run_script << 'EOF'
j=$(@submit sleep 30)
@wait "$j"
echo "wait-rc=$?"
@cancel "$j" > /dev/null
EOF
  assert_contains "$OUT" "gave up waiting after 1s (RUNFLOW_WAIT_TIMEOUT); the job keeps running"
  assert_contains "$OUT" "wait-rc=1"
}

test_wait_invalid_timeout() {
  export RUNFLOW_WAIT_TIMEOUT=abc
  run "$RUNFLOW" -c @wait "$TEST_SCHEDULER:1"
  assert_rc 1
  assert_contains "$OUT" "RUNFLOW_WAIT_TIMEOUT must be a number of seconds"
}

# The fallback tests replace runflow::load_queue_backend with a fake backend that has
# no runflow::backend_wait_job, so @wait must poll runflow::backend_job_status

test_wait_polling_fallback() {
  export RUNFLOW_POLL=0.1
  run_script << 'EOF'
runflow::load_queue_backend() {
  unset -f runflow::backend_wait_job
  runflow::backend_job_status() {
    local n=$(( $(cat polls 2> /dev/null || echo 0) + 1 ))
    echo "$n" > polls
    if (( n < 3 )); then echo RUNNING; else echo COMPLETED; fi
  }
}
@wait localq:1
echo "wait-rc=$? polls=$(cat polls)"
EOF
  assert_contains "$OUT" "wait-rc=0 polls=3"
}

test_wait_polling_fallback_timeout() {
  export RUNFLOW_POLL=0.1 RUNFLOW_WAIT_TIMEOUT=1
  run_script << 'EOF'
runflow::load_queue_backend() {
  unset -f runflow::backend_wait_job
  runflow::backend_job_status() { echo RUNNING; }
}
@wait localq:1
echo "wait-rc=$?"
EOF
  assert_contains "$OUT" "gave up waiting after 1s"
  assert_contains "$OUT" "wait-rc=1"
}

test_wait_polling_fallback_backend_errors() {
  export RUNFLOW_POLL=0.1
  run_script << 'EOF'
runflow::load_queue_backend() {
  unset -f runflow::backend_wait_job
  runflow::backend_job_status() { echo "scheduler unreachable" >&2; return 1; }
}
@wait localq:1
echo "wait-rc=$?"
EOF
  assert_contains "$OUT" "scheduler unreachable"
  assert_contains "$OUT" "cannot get status from localq"
  assert_contains "$OUT" "wait-rc=1"
}

# --- @wait @directive: run the directive, wait for the jobs it prints ---

test_wait_directive_submits_waits_and_prints_id() {
  run_script << 'EOF'
j=$(@wait @submit sh -c 'sleep 1; touch done.txt' 2> wait.log)
echo "rc=$? id=$j done=$([[ -e done.txt ]] && echo yes)"
cat wait.log
EOF
  assert_contains "$OUT" "rc=0 id=$TEST_SCHEDULER:1 done=yes"
  assert_contains "$OUT" "Job $TEST_SCHEDULER:1 completed successfully"
}

test_wait_directive_returns_job_failure() {
  run "$RUNFLOW" -c @wait @submit false
  assert_rc 1
  assert_contains "$OUT" "failed"
}

test_wait_directive_waits_for_every_job_it_prints() {
  run_script << 'EOF'
@two() { @submit sh -c 'sleep 1; touch a.done'; @submit sh -c 'sleep 1; touch b.done'; }
ids=$(@wait @two)
echo "rc=$? ids=$(echo $ids) done=$(ls *.done | awk 'END { print NR }')"
EOF
  assert_contains "$OUT" "rc=0 ids=$TEST_SCHEDULER:1 $TEST_SCHEDULER:2 done=2"
}

test_wait_directive_failure_does_not_wait_for_other_jobs() {
  # A failed submission is reported; @wait does not fall back to all jobs
  run_script << 'EOF'
@submit sleep 30 > /dev/null
start=$(date +%s)
@wait @submit --bogus true
echo "rc=$? took=$(( $(date +%s) - start ))"
@cancel > /dev/null
EOF
  assert_contains "$OUT" "unknown option: --bogus"
  assert_contains "$OUT" "rc=1 took="
  local took
  took=$(sed -n 's/.*took=\([0-9]*\).*/\1/p' <<< "$OUT")
  (( took < 5 )) || fail "@wait waited ${took}s for an unrelated job"
}

test_wait_directive_without_job_ids_fails() {
  run "$RUNFLOW" -c @wait @flow A.DATA
  assert_rc 1
  assert_contains "$OUT" "@wait: @flow printed no job ID"
  assert_contains "$OUT" "ARGV [$PWD/A.DATA]"   # the directive's output passes through
  assert_not_contains "$OUT" "unknown job"
}

test_wait_quoted_failed_submission_fails() {
  run_script << 'EOF'
@wait "$(@submit --bogus true)"
echo "rc=$?"
EOF
  assert_contains "$OUT" "No job ID provided"
  assert_contains "$OUT" "rc=1"
}

test_wait_directive_in_dry_run() {
  run "$RUNFLOW" --dry-run -c @wait @submit true
  assert_rc 0
  assert_contains "$OUT" "[DRY-RUN] wait $TEST_SCHEDULER:dry1"
}
