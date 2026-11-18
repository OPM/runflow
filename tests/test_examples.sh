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
    run "$FLOWRUN" --dry-run "$ROOT/examples/"${example%:*}
    assert_rc 0
    assert_contains "$OUT" "done: ${example##*:} job(s) would be submitted"
  done
}

test_scaling_caps_default_ranks_at_the_cores() {
  use_decks
  local np expected=0 cores
  cores=$(getconf _NPROCESSORS_ONLN)
  for np in 1 2 4 8; do (( np <= cores )) && expected=$((expected + 1)); done
  run "$FLOWRUN" --dry-run "$ROOT/examples/5_scaling.sh"
  assert_rc 0
  assert_contains "$OUT" "done: $expected job(s) would be submitted"
}

test_sensitivity_multiplies_at_the_end_of_the_grid() {
  use_decks
  run "$FLOWRUN" --dry-run "$ROOT/examples/3_sensitivity.sh"
  local deck=runs/sensitivity/PERMZ_10/PERMZ_10.DATA
  assert_eq "$(grep -A1 '^MULTIPLY' "$deck" | tail -1)" "  'PERMZ' 10 /"
  assert_eq "$(grep -e '^MULTIPLY' -e '^PROPS' "$deck" | tr '\n' ' ')" "MULTIPLY PROPS "
  [[ -f runs/sensitivity/PERMX_0p5/PERMX_0p5.DATA ]] || fail "no dot in run names"
}

test_prediction_scenarios_restart_from_the_history() {
  use_decks
  run "$FLOWRUN" --dry-run "$ROOT/examples/4_prediction_scenarios.sh"
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
  run "$FLOWRUN" --dry-run "$ROOT/examples/6_history_match.sh"
  assert_contains "$OUT" "(dry run: the iterations need the results)"
  local truth=runs/history_match/truth/CASE.DATA
  assert_file_contains "$truth" "  'PERMX' 0.4 1 10 1 10 1 1 /"
  assert_file_contains "$truth" "  'PERMY' 2 1 10 1 10 2 2 /"
  assert_eq "$(tail -1 "$truth")" "END"
}

test_compare_versions_needs_two_versions() {
  use_decks
  run "$FLOWRUN" "$ROOT/examples/2_compare_versions.sh" flowtest
  assert_rc 1
  assert_contains "$OUT" "usage: flowrun"
}

# --- Real runs (TEST_FLOW, TEST_DECKS) ---

use_real_flow() {
  [[ -x "${TEST_FLOW:-}" && -d "${TEST_DECKS:-}" ]] || skip "TEST_FLOW and TEST_DECKS not set"
  export OPM_DECKS="$TEST_DECKS"
  cat >> "$FLOWRUN_CONFIG" << EOF
FLOWRUN_FLOW_VERSIONS=('real=$TEST_FLOW' 'realpy=${TEST_FLOWPY:-$TEST_FLOW}')
FLOWRUN_FLOW_VERSION=real
FLOWRUN_FLOWPY_VERSION=realpy
FLOWRUN_FLOW_PYTHONPATH=auto
FLOWRUN_FLOW_PYTHON_MAP=()
FLOWRUN_MPI_LAUNCHER_LOCAL='mpirun -np {np} --bind-to none'
EOF
}

test_real_run_case() {
  use_real_flow
  run "$FLOWRUN" "$ROOT/examples/1_run_case.sh" "$TEST_DECKS/SPE1CASE2.DATA"
  assert_rc 0
  assert_contains "$OUT" "[INFO] @flow: flow real:"
  assert_contains "$OUT" "runs/run_case/SPE1CASE2.DATA: FOPR last"
}

test_real_compare_versions() {
  use_real_flow
  run "$FLOWRUN" "$ROOT/examples/2_compare_versions.sh" real real
  assert_rc 0
  assert_contains "$OUT" "PASS"
}
