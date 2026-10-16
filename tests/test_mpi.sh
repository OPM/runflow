#!/usr/bin/env bash
# @mpi: MPI launcher per scheduler, launcher options, plain commands

# Append settings to the sandbox configuration
set_config() {
  printf '%s\n' "$@" >> "$OPMEXEC_CONFIG"
}

test_mpi_runs_flow_locally() {
  require_cmd mpirun
  run "$OPMEXEC" -c @mpi -n 2 @flow A.DATA
  assert_rc 0
  assert_eq "$(grep -c '^FLOW' <<< "$OUT")" 2
  assert_contains "$OUT" "np=2"
}

test_mpi_np_defaults_to_opmexec_np() {
  require_cmd mpirun
  run "$OPMEXEC" -n 2 -c @mpi @flow A.DATA
  assert_rc 0
  assert_eq "$(grep -c '^FLOW' <<< "$OUT")" 2
}

test_mpi_runs_plain_commands() {
  require_cmd mpirun
  run "$OPMEXEC" -c @mpi -n 2 sh -c 'echo "rank ${OMPI_COMM_WORLD_RANK:-${PMI_RANK:-?}}"'
  assert_rc 0
  assert_eq "$(grep -c '^rank' <<< "$OUT")" 2
}

test_mpi_inside_job_uses_job_np() {
  require_cmd mpirun
  run "$OPMEXEC" -c @wait @submit -n 2 -o "$PWD/out.log" @mpi @flow A.DATA
  assert_rc 0
  assert_eq "$(grep -c '^FLOW' out.log)" 2
}

test_mpi_launcher_options_order() {
  # Configured launcher, then opmexec --mpi-options, then @mpi -o
  set_config "OPMEXEC_MPI_LAUNCHER_LOCAL='mpirun -np {np} --site=\"a b\"'"
  run "$OPMEXEC" --dry-run --mpi-options "--workflow=1" -c @mpi -n 3 -o "--call=2" @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 3 --site=a\\ b --workflow=1 --call=2 env PYTHONPATH="
}

test_mpi_launcher_per_scheduler() {
  # Inside a job the job's scheduler selects the launcher; localq uses LOCAL
  local scheduler expected
  for pair in "slurm:srun --ntasks=8" "lsf:mpirun -np 8" "pbs:mpirun -np 8" \
              "localq:mpirun -np 8"; do
    scheduler=${pair%%:*}
    expected=${pair#*:}
    run "$OPMEXEC" --dry-run -s "$scheduler" -c @submit -n 8 @mpi @flow A.DATA
    assert_rc 0
    assert_contains "$OUT" "run: $expected env PYTHONPATH="
  done
}

test_mpi_local_launcher_outside_jobs() {
  run "$OPMEXEC" --dry-run -s slurm -c @mpi -n 4 @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 4 env PYTHONPATH="
}

test_mpi_launcher_not_found() {
  set_config "OPMEXEC_MPI_LAUNCHER_LOCAL='no-such-launcher -n {np}'"
  run "$OPMEXEC" -c @mpi -n 2 @flow A.DATA
  assert_rc 1
  assert_contains "$OUT" "MPI launcher not found: no-such-launcher (set OPMEXEC_MPI_LAUNCHER_LOCAL)"
}

test_mpi_rejects_directives_without_command() {
  run "$OPMEXEC" -c @mpi @submit true
  assert_rc 1
  assert_contains "$OUT" "@submit cannot run under @mpi"
}

test_mpi_rejects_bad_np() {
  run "$OPMEXEC" -c @mpi -n 0 @flow A.DATA
  assert_rc 1
  assert_contains "$OUT" "must be a positive integer"
}

test_mpi_passes_flow_errors() {
  run "$OPMEXEC" -c @mpi -n 2 @flow MISSING.DATA
  assert_rc 1
  assert_contains "$OUT" "Input deck not found: MISSING.DATA"
}
