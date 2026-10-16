#!/usr/bin/env bash
# Native scheduler options (--<scheduler>-options)

test_scheduler_options_apply_per_scheduler() {
  # Configuration, then opmexec, then @submit options; other schedulers' ignored
  printf '%s\n' "OPMEXEC_SLURM_OPTIONS='--account=site'" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" --dry-run -s slurm --slurm-options "--qos=wf" --lsf-options "-q wf" \
    -c @submit --slurm-options "--time=1:00" --lsf-options "-W 1:00" true
  assert_rc 0
  assert_contains "$OUT" "options=--account=site --qos=wf --time=1:00"
  assert_not_contains "$OUT" "-W 1:00"
  assert_not_contains "$OUT" "-q wf"

  run "$OPMEXEC" --dry-run -s lsf --slurm-options "--qos=wf" \
    -c @submit --slurm-options "--time=1:00" --lsf-options "-R 'span[hosts=1]'" true
  assert_rc 0
  assert_contains "$OUT" "options=-R 'span[hosts=1]'"
  assert_not_contains "$OUT" "--time"
}

test_scheduler_options_without_matching_options() {
  run "$OPMEXEC" --dry-run -s slurm -c @submit --lsf-options "-W 1:00" true
  assert_rc 0
  assert_not_contains "$OUT" "options="
}

test_scheduler_options_reject_unbalanced_quotes() {
  run "$OPMEXEC" --dry-run -s slurm -c @submit --slurm-options "--comment='x" true
  assert_rc 1
  assert_contains "$OUT" "Unbalanced quotes in --slurm-options"
}

test_scheduler_options_ignored_by_localq() {
  require_localq
  run "$OPMEXEC" -c @wait @submit --slurm-options "--time=1:00" --lsf-options "-W 1:00" true
  assert_rc 0
  assert_contains "$OUT" "completed successfully"
}

test_unknown_scheduler_options_rejected() {
  run "$OPMEXEC" -c @submit --foo-options "x" true
  assert_rc 1
  assert_contains "$OUT" "Unknown option: --foo-options"
}

# --- Options for every invocation of a directive (--<directive>-options) ---

test_flow_options_apply_to_every_flow() {
  run "$OPMEXEC" --flow-options "--a='x y'" -c @flow --b=2 A.DATA
  assert_rc 0
  assert_contains "$OUT" "ARGV [--a=x y] [--b=2] [$PWD/A.DATA]"
}

test_flow_options_layers_and_jobs() {
  # Site default (configuration), then opmexec --flow-options, then -o; the
  # workflow's options reach @flow inside jobs
  printf '%s\n' "OPMEXEC_FLOW_OPTIONS='--site=1'" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" --flow-options "--wf=2" -c @wait @submit -o "$PWD/out.log" @flow --call=3 A.DATA
  assert_rc 0
  assert_file_contains out.log "ARGV [--site=1] [--wf=2] [--call=3] [$PWD/A.DATA]"
}

test_flow_options_under_mpi() {
  run "$OPMEXEC" --dry-run --flow-options "--x=1" --mpi-options "--y=2" -c @mpi -n 2 @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 2 --y=2 env PYTHONPATH="
  assert_contains "$OUT" "flowtest --x=1 $PWD/A.DATA"
}

test_flow_options_with_setup_when_sourcing() {
  cat > sourcing.sh << EOF
source "$ROOT/lib/opmexec.sh" || exit 1
opmexec::setup --flow-options "--from-setup" || exit 1
@flow A.DATA
EOF
  run bash sourcing.sh
  assert_rc 0
  assert_contains "$OUT" "ARGV [--from-setup] [$PWD/A.DATA]"
}

test_flowpy_options() {
  run "$OPMEXEC" --dry-run --flowpy-options "-u -X dev" -c @flowpy script.py
  [[ "$OUT" =~ run:\ env\ PYTHONPATH=[^\ ]+\ [^\ ]*python3\.11\ -u\ -X\ dev\ script\.py ]] || fail "unexpected command: $OUT"
}

test_directive_without_options_rejects_them() {
  mkdir "$SANDBOX/directives"
  printf '%s\n' 'opmexec::directive hello "" "Say hello"' '@hello() { echo hello; }' \
    > "$SANDBOX/directives/hello.sh"
  export OPMEXEC_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$OPMEXEC" --hello-options "x" -c @hello
  assert_rc 1
  assert_contains "$OUT" "Unknown option: --hello-options (@hello takes no options)"
}

test_unknown_name_options_list_alternatives() {
  run "$OPMEXEC" --foo-options "x" -c true
  assert_rc 1
  assert_contains "$OUT" "native scheduler options exist for: lsf, slurm, pbs, localq"
  assert_contains "$OUT" "Directive options exist for: mpi flow flowpy"
}

test_directive_cannot_take_a_scheduler_name() {
  mkdir "$SANDBOX/directives"
  printf '%s\n' 'opmexec::directive slurm "" "Clash" "Options"' '@slurm() { echo clash; }' \
    > "$SANDBOX/directives/slurm.sh"
  export OPMEXEC_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$OPMEXEC" -c true
  assert_contains "$OUT" "@slurm: the name of a scheduler cannot be used for a directive"
}

test_help_shows_directive_options() {
  run "$OPMEXEC" -c @help @flow
  assert_contains "$OUT" "--flow-options OPTS"
  assert_contains "$OUT" "Flow options for every @flow"
  run "$OPMEXEC" -c @mpi --help
  assert_contains "$OUT" "MPI launcher options for every @mpi"
}
