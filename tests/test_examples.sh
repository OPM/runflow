#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# The examples: dry runs with small stand-in decks (just the keywords the
# examples edit), the decks they derive, and optionally real runs:
#   TEST_FLOW=/path/to/flow [TEST_FLOWPY=/path/to/flow-with-python]
#   TEST_DECKS=/path/to/opm-common/tests
# (skipped without them)

# Stand-ins for SPE1CASE2 and SPE9_CP_PACKED, in OPM_DECKS
use_decks() {
  mkdir -p "$SANDBOX/decks"
  local name
  for name in SPE1CASE2 SPE9_CP_PACKED; do
    cat > "$SANDBOX/decks/$name.DATA" << 'EOF'
RUNSPEC
GRID
PERMX
  300*100 /
PROPS
SOLUTION
EQUIL
  8400 4800 8450 0 8300 0 1 0 0 /
SUMMARY
FOPR
SCHEDULE
TSTEP
  31 /
DATES
  31 'DEC' 2019 /
/
TSTEP
  31 /
END
EOF
  done
  export OPM_DECKS="$SANDBOX/decks"
}

test_examples_dry_run() {
  use_decks
  local example
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  # 5_scaling.sh with its rank counts given: by default it caps them at this
  # machine's cores (next test)
  for example in "1_run_case.sh:0" "2_compare_versions.sh flowtest flowrc47:0" "3_sensitivity.sh:7" \
                 "4_prediction_scenarios.sh:4" "5_scaling.sh $SANDBOX/decks/SPE9_CP_PACKED.DATA 1 2 4 8:4" \
                 "6_history_match.sh:1"; do
    # shellcheck disable=SC2086  # the example's arguments
    run "$RUNFLOW" --dry-run "$ROOT/examples/"${example%:*}
    assert_rc 0
    assert_contains "$OUT" "done: ${example##*:} job(s) would be submitted"
  done
}

test_scaling_caps_default_ranks_at_the_cores() {
  use_decks
  local np expected=0 cores
  cores=$(getconf _NPROCESSORS_ONLN)
  for np in 1 2 4 8; do (( np <= cores )) && expected=$((expected + 1)); done
  run "$RUNFLOW" --dry-run "$ROOT/examples/5_scaling.sh"
  assert_rc 0
  assert_contains "$OUT" "done: $expected job(s) would be submitted"
}

test_sensitivity_multiplies_at_the_end_of_the_grid() {
  use_decks
  run "$RUNFLOW" --dry-run "$ROOT/examples/3_sensitivity.sh"
  local deck=runs/sensitivity/PERMZ_10/PERMZ_10.DATA
  assert_eq "$(grep -A1 '^MULTIPLY' "$deck" | tail -1)" "  'PERMZ' 10 /"
  assert_eq "$(grep -e '^MULTIPLY' -e '^PROPS' "$deck" | tr '\n' ' ')" "MULTIPLY PROPS "
  [[ -f runs/sensitivity/PERMX_0p5/PERMX_0p5.DATA ]] || fail "no dot in run names"
}

test_prediction_scenarios_restart_from_the_history() {
  use_decks
  run "$RUNFLOW" --dry-run "$ROOT/examples/4_prediction_scenarios.sh"
  assert_eq "$(grep -c 'depends_on=dry1' <<< "$OUT")" 3
  local history=runs/prediction_scenarios/HISTORY/HISTORY.DATA scenario=runs/prediction_scenarios/MORE_GAS/MORE_GAS.DATA
  assert_eq "$(tail -1 "$history")" "END"
  assert_eq "$(grep -c '^TSTEP' "$history")" 1
  assert_file_contains "$scenario" "  '../HISTORY/HISTORY' 60 /"
  [[ "$(grep -c '^EQUIL' "$scenario")" == 0 ]] || fail "EQUIL kept"
  assert_eq "$(grep -A1 '^RUNSPEC' "$scenario" | tail -1)" "UNIFIN"
  assert_eq "$(grep -A1 '^SCHEDULE' "$scenario" | tail -1)" "SKIPREST"
  assert_eq "$(grep -A2 "31 'DEC' 2019" "$scenario" | tail -1)" "WCONINJE"
}

test_history_match_multiplies_each_layer() {
  use_decks
  run "$RUNFLOW" --dry-run "$ROOT/examples/6_history_match.sh"
  assert_contains "$OUT" "(dry run: the iterations need the results)"
  local truth=runs/history_match/truth/CASE.DATA
  assert_file_contains "$truth" "  'PERMX' 0.4 1 10 1 10 1 1 /"
  assert_file_contains "$truth" "  'PERMY' 2 1 10 1 10 2 2 /"
  assert_eq "$(tail -1 "$truth")" "END"
}

# --- legacy/legacy-runflow: a site's runflow script on runflow's library ---

legacy_runflow() {
  PATH="$ROOT:$PATH" run "$ROOT/examples/legacy/legacy-runflow" "$@"
}

test_legacy_runflow_submits_a_job_like_the_legacy_script() {
  # Its options (also -np and -op), as a job: queue, processes, version,
  # Flow's options, the deck's name, its .LOG next to it
  mkdir deck && touch deck/CASE.DATA
  run "$RUNFLOW" --dry-run "$ROOT/examples/legacy/legacy-runflow" -np 2 -q long -v flowtest -op "--a='x y'" deck/CASE.DATA
  assert_rc 0
  assert_contains "$OUT" "queue=long np=2 output=$PWD/deck/CASE.LOG options=--job-name=CASE"
  assert_contains "$OUT" "command: @mpi @flow CASE.DATA"
  assert_contains "$OUT" "run: mpirun -np 2 env PYTHONPATH="
  assert_contains "$OUT" "bin/flowtest --a=x\\ y $PWD/deck/CASE.DATA"
}

test_legacy_runflow_runs_here_and_lists() {
  # -i: here and now, one process without MPI, from the deck's directory;
  # found through PATH (runflow.bash too); -l: the versions
  mkdir deck && touch deck/CASE.DATA
  legacy_runflow -i -o "--x=1" deck/CASE.DATA
  assert_rc 0
  assert_contains "$OUT" "ARGV [--x=1] [$PWD/deck/CASE.DATA]"
  assert_contains "$OUT" "np=1"
  legacy_runflow -l
  assert_contains "$OUT" "flowtest  2099.10"
}

test_legacy_runflow_site_configuration_reproduces_its_job() {
  # The example site.conf: the LSF job such scripts submit
  touch CASE.DATA
  RUNFLOW_CONFIG="$ROOT/examples/legacy/site.conf" run "$RUNFLOW" --dry-run -s lsf \
    "$ROOT/examples/legacy/legacy-runflow" -n 4 CASE.DATA
  assert_rc 0
  assert_contains "$OUT" "submit lsf:dry1: queue=normal np=4 output=$PWD/CASE.LOG options=-R span[hosts=1] -J CASE"
  assert_contains "$OUT" "run: mpirun -np 4 --bind-to none -x OMP_NUM_THREADS=1 env PYTHONPATH=/opt/opm/lib/python3.11/site-packages/flowrc45 "
}

test_legacy_runflow_rejects_what_the_legacy_script_did() {
  legacy_runflow -n
  assert_rc 2
  assert_contains "$OUT" "-n needs a value"
  legacy_runflow --bogus CASE.DATA
  assert_rc 2
  legacy_runflow
  assert_rc 4
  assert_contains "$OUT" "one deck is required"
}

test_compare_versions_needs_two_versions() {
  use_decks
  run "$RUNFLOW" "$ROOT/examples/2_compare_versions.sh" flowtest
  assert_rc 1
  assert_contains "$OUT" "usage: runflow"
}

# --- Real runs (TEST_FLOW, TEST_DECKS) ---

use_real_flow() {
  [[ -x "${TEST_FLOW:-}" && -d "${TEST_DECKS:-}" ]] || skip "TEST_FLOW and TEST_DECKS not set"
  export OPM_DECKS="$TEST_DECKS"
  cat >> "$RUNFLOW_CONFIG" << EOF
RUNFLOW_FLOW_VERSIONS=('real=$TEST_FLOW' 'realpy=${TEST_FLOWPY:-$TEST_FLOW}')
RUNFLOW_FLOW_VERSION=real
RUNFLOW_FLOWPY_VERSION=realpy
RUNFLOW_FLOW_PYTHONPATH=auto
RUNFLOW_FLOW_PYTHON_MAP=()
RUNFLOW_MPI_LAUNCHER_LOCAL='mpirun -np {np} --bind-to none'
EOF
}

test_real_run_case() {
  use_real_flow
  run "$RUNFLOW" "$ROOT/examples/1_run_case.sh" "$TEST_DECKS/SPE1CASE2.DATA"
  assert_rc 0
  assert_contains "$OUT" "[INFO] @flow: flow real:"
  assert_contains "$OUT" "runs/run_case/SPE1CASE2.DATA: FOPR last"
}

test_real_compare_versions() {
  use_real_flow
  run "$RUNFLOW" "$ROOT/examples/2_compare_versions.sh" real real
  assert_rc 0
  assert_contains "$OUT" "PASS"
}
