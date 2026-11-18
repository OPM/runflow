#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# What jobs need on another host: workflow settings passed explicitly, job setup

saved_command() {
  cat "$(localq_dir)/$1/cmd"
}

test_job_gets_settings_that_were_not_exported() {
  # Sites may not pass the environment on: a setting the job only gets through
  # the environment would be lost. A non-exported variable shows the
  # difference, as the localq runner only inherits exported ones.
  require_localq
  cat > sourcing.sh << EOF
source "$ROOT/lib/runflow.sh" || exit 1
RUNFLOW_FLOW_OPTIONS="--not-exported"
@wait @submit -o "\$PWD/out.log" @flow A.DATA
EOF
  run bash sourcing.sh
  assert_rc 0
  assert_file_contains out.log "ARGV [--not-exported] [$PWD/A.DATA]"
}

test_job_command_carries_workflow_settings_only() {
  require_localq
  run "$RUNFLOW" -q other --flow-options "--x=1" -c @wait @submit true
  assert_rc 0
  local cmd
  cmd=$(saved_command 1)
  for setting in RUNFLOW_JOB_SCHEDULER=localq "RUNFLOW_CONFIG=$RUNFLOW_CONFIG" \
                 RUNFLOW_SCHEDULER=localq RUNFLOW_FLOW_OPTIONS=--x=1 RUNFLOW_MPI_OPTIONS= \
                 RUNFLOW_DIRECTIVE_PATH= RUNFLOW_DEBUG=false; do
    [[ "$cmd" == *" $setting"* ]] || fail "job command lacks $setting: $cmd"
  done
  [[ "$cmd" == *" RUNFLOW_NP=1 "* ]] || fail "job command lacks its process count"
  for setting in RUNFLOW_QUEUE RUNFLOW_DEPENDS_ON RUNFLOW_SLURM_OPTIONS; do
    [[ "$cmd" != *" $setting="* ]] || fail "job command should not pass $setting"
  done
}

test_relative_config_path_is_made_absolute() {
  require_localq
  cp "$RUNFLOW_CONFIG" my.conf
  RUNFLOW_CONFIG=my.conf run "$RUNFLOW" -c @wait @submit true
  assert_rc 0
  [[ "$(saved_command 1)" == *" RUNFLOW_CONFIG=$PWD/my.conf "* ]] || fail "config path not absolute"
}

test_job_setup_runs_first() {
  printf '%s\n' "RUNFLOW_JOB_SETUP='export GREETING=\"hi there\"'" >> "$RUNFLOW_CONFIG"
  run "$RUNFLOW" -c @wait @submit -o "$PWD/out.log" sh -c 'echo "setup says $GREETING"'
  assert_rc 0
  assert_file_contains out.log "setup says hi there"
}

test_job_setup_failure_fails_the_job() {
  printf '%s\n' "RUNFLOW_JOB_SETUP='false'" >> "$RUNFLOW_CONFIG"
  run "$RUNFLOW" -c @wait @submit -o "$PWD/out.log" touch ran.txt
  assert_rc 1
  assert_contains "$OUT" "failed"
  assert_file_contains out.log "runflow: job setup failed: false"
  [[ ! -e ran.txt ]] || fail "the command ran after the setup failed"
}

test_listing_hides_setup_and_settings() {
  require_localq
  printf '%s\n' "RUNFLOW_JOB_SETUP='export A=\"1 2\"'" >> "$RUNFLOW_CONFIG"
  run "$RUNFLOW" --flow-options "--x='a b'" -c @wait @submit @mpi @flow A.DATA
  run "$RUNFLOW" --jobs=all
  assert_contains "$OUT" "  @mpi @flow A.DATA"
  assert_not_contains "$OUT" "RUNFLOW_"
  assert_not_contains "$OUT" "runflow-job"
}

test_job_process_count_reaches_scripts_in_the_job() {
  # A job running a script (not a directive) still gets its own -n: @mpi in
  # the script defaults to it, not to the submitting workflow's -n
  cat > job.sh << EOF
#!/usr/bin/env bash
source "$ROOT/lib/runflow.sh" || exit 1
echo "np=\$RUNFLOW_NP"
RUNFLOW_DRY_RUN=true @mpi @flow A.DATA
EOF
  chmod +x job.sh
  run "$RUNFLOW" -n 1 -c @wait @submit -n 3 -o "$PWD/out.log" ./job.sh
  assert_rc 0
  assert_file_contains out.log "np=3"
  assert_file_contains out.log "run: mpirun -np 3"
}
