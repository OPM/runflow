#!/usr/bin/env bash
# --dry-run: check workflows without submitting or running anything

test_dry_run_submits_and_runs_nothing() {
  run_script --dry-run << 'EOF'
j=$(@submit true)
@wait @submit @flow A.DATA
@flow A.DATA
@wait
@cancel "$j"
EOF
  assert_rc 0
  assert_contains "$OUT" "[DRY-RUN] submit $TEST_SCHEDULER:dry1"
  assert_contains "$OUT" "[DRY-RUN] wait $TEST_SCHEDULER:dry2"
  assert_contains "$OUT" "[DRY-RUN] cancel $TEST_SCHEDULER:dry1"
  assert_contains "$OUT" "done: 2 job(s) would be submitted"
  assert_not_contains "$OUT" "FLOW exe="
  [[ ! -d "$(localq_dir)" ]] || fail "localq state was created"
}

test_dry_run_returns_fake_ids() {
  run_script --dry-run << 'EOF'
a=$(@submit true)
b=$(@submit --depends-on "$a" true)
echo "ids=$a,$b"
EOF
  assert_rc 0
  assert_contains "$OUT" "ids=$TEST_SCHEDULER:dry1,$TEST_SCHEDULER:dry2"
  assert_contains "$OUT" "depends_on=dry1"
}

test_dry_run_shows_flow_command() {
  run "$FLOWRUN" --dry-run -c @flow --x=1 A.DATA
  assert_rc 0
  assert_contains "$OUT" "[DRY-RUN] run: env PYTHONPATH="
  assert_contains "$OUT" "$SANDBOX/bin/flowtest --x=1 $PWD/A.DATA"
}

test_dry_run_checks_flow_inside_jobs() {
  run_script --dry-run << 'EOF'
@submit @mpi --oops @flow A.DATA
@submit @flow -v nope MISSING.DATA
EOF
  assert_rc 0
  assert_contains "$OUT" "unknown option: --oops"
  assert_contains "$OUT" "warning: @mpi would fail inside job $TEST_SCHEDULER:dry1"
  assert_contains "$OUT" "warning: input deck not found (yet?): MISSING.DATA"
  assert_contains "$OUT" "warning: Flow version not found: nope"
}

test_dry_run_works_without_backend() {
  run "$FLOWRUN" --dry-run -s slurm -c @wait @submit -n 8 true
  assert_rc 0
  assert_contains "$OUT" "[DRY-RUN] submit slurm:dry1: queue=default np=8"
}

test_dry_run_still_rejects_cross_scheduler_dependency() {
  run "$FLOWRUN" --dry-run -s slurm -c @submit --depends-on localq:1 true
  assert_rc 1
  assert_contains "$OUT" "cannot be a dependency"
}

test_dry_run_flag_visible_to_scripts() {
  run_script --dry-run << 'EOF'
echo "dry=$FLOWRUN_DRY_RUN"
EOF
  assert_contains "$OUT" "dry=true"
}
