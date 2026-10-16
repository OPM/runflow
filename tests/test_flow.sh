#!/usr/bin/env bash
# @flow: local Flow runs

test_flow_runs_locally_with_defaults() {
  run "$OPMEXEC" -c @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowtest args=$PWD/A.DATA np=1"
  assert_contains "$OUT" "pythonpath=$SANDBOX/lib/python3.11/site-packages/flowtest"
}

test_flow_makes_deck_path_absolute() {
  mkdir decks
  touch decks/C.DATA
  run "$OPMEXEC" -c @flow decks/C.DATA
  assert_rc 0
  assert_contains "$OUT" "args=$PWD/decks/C.DATA"
}

test_flow_passes_its_arguments_to_flow() {
  # As for flow itself: options, in any order, and the deck (made absolute)
  run "$OPMEXEC" -c @flow --a=1 A.DATA "--b=x y"
  assert_rc 0
  assert_contains "$OUT" "ARGV [--a=1] [$PWD/A.DATA] [--b=x y]"
}

test_flow_version_and_help_are_flows() {
  run "$OPMEXEC" -c @flow --version
  assert_rc 0
  assert_contains "$OUT" "flow 2099.10"
  run "$OPMEXEC" -c @flow -v flowtest --help
  assert_contains "$OUT" "ARGV [--help]"
  # After --, also @flow's own options go to Flow
  run "$OPMEXEC" -c @flow -- -l
  assert_contains "$OUT" "ARGV [-l]"
}

test_flow_which_prints_the_executable() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" -c @flow -w
  assert_rc 0
  assert_eq "$OUT" "$SANDBOX/bin/flowtest"
  run "$OPMEXEC" -c @flow --which flowrc47
  assert_eq "$OUT" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" -c @flow -w nope
  assert_rc 1
  assert_contains "$OUT" "Flow version not found: nope"
}

test_flow_selects_version() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" -c @flow -v flowrc47 A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowrc47"
  assert_contains "$OUT" "pythonpath=$SANDBOX/lib/python3.12/site-packages/flowrc47"
}

test_flow_runs_one_process_even_with_opmexec_np() {
  run "$OPMEXEC" -n 4 -c @flow A.DATA
  assert_rc 0
  assert_eq "$(grep -c '^FLOW' <<< "$OUT")" 1
}

test_flow_rejects_np_with_hint() {
  run "$OPMEXEC" -c @flow -n 2 A.DATA
  assert_rc 1
  assert_contains "$OUT" "no -n option; to run Flow with MPI: @mpi -n 2 @flow"
}

test_flow_options_use_shell_quoting() {
  run "$OPMEXEC" --flow-options "--a='x y' --b=\"p q\" --c=r\\ s" -c @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "ARGV [--a=x y] [--b=p q] [--c=r s] [$PWD/A.DATA]"
}

test_flow_options_reject_unbalanced_quotes() {
  run "$OPMEXEC" --flow-options "--a='x" -c @flow A.DATA
  assert_rc 1
  assert_contains "$OUT" "Unbalanced quotes in --flow-options"
}

test_flow_exit_code_propagates() {
  export FAKE_RC=5
  run "$OPMEXEC" -c @flow A.DATA
  assert_rc 5
}

test_flow_without_arguments_runs_flow() {
  run "$OPMEXEC" -c @flow
  assert_rc 0
  assert_contains "$OUT" "ARGV"
}

test_flow_missing_deck_fails() {
  run "$OPMEXEC" -c @flow MISSING.DATA
  assert_rc 1
  assert_contains "$OUT" "Input deck not found: MISSING.DATA"
}

test_flow_unknown_version_fails() {
  run "$OPMEXEC" -c @flow -v nope A.DATA
  assert_rc 1
  assert_contains "$OUT" "Flow version not found: nope"
}

test_flow_lists_and_which_work_on_their_own() {
  run "$OPMEXEC" -c @flow -v flowtest -l
  assert_rc 1
  assert_contains "$OUT" "@flow: -l works on its own: @flow -l [VERSION]"
}

test_flow_lists_versions() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" -c @flow -l
  assert_rc 0
  assert_contains "$OUT" "$SANDBOX/bin"
  assert_contains "$OUT" "   flowrc47  2099.10"
  assert_contains "$OUT" " * flowtest  2099.10"
  assert_contains "$OUT" "* the default (OPMEXEC_FLOW_VERSION=flowtest)"
}

# --- Finding Flow: OPMEXEC_FLOW_BIN_PATHS, PATH, OPM Flow only ---

# Search only PATH (the default)
use_path_search() {
  printf '%s\n' "OPMEXEC_FLOW_BIN_PATHS=(PATH)" >> "$OPMEXEC_CONFIG"
}

# A program named NAME in DIR that is not OPM Flow (as Meta's JavaScript flow)
fake_other_flow() {
  mkdir -p "$1"
  printf '%s\n' '#!/bin/sh' 'echo "Flow, a static type checker for JavaScript, version 0.250.0"' > "$1/$2"
  chmod +x "$1/$2"
}

test_flow_found_in_path_by_default() {
  use_path_search
  mkdir "$SANDBOX/modules"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/modules/flowmod"
  PATH="$SANDBOX/modules:$PATH" run "$OPMEXEC" -c @flow -v flowmod A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/modules/flowmod"
}

test_flow_path_resolved_inside_jobs() {
  # The job's PATH (after OPMEXEC_JOB_SETUP) decides, not the submitter's
  use_path_search
  mkdir "$SANDBOX/modules"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/modules/flowmod"
  printf '%s\n' "OPMEXEC_JOB_SETUP='PATH=$SANDBOX/modules:\$PATH'" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @wait @submit -o "$PWD/out.log" @flow -v flowmod A.DATA
  assert_rc 0
  assert_file_contains out.log "exe=$SANDBOX/modules/flowmod"
}

test_flow_relative_path_entries_ignored() {
  use_path_search
  cp "$SANDBOX/bin/flowtest" ./flowhere
  PATH=".:$PATH" run "$OPMEXEC" -c @flow -v flowhere A.DATA
  assert_rc 1
  assert_contains "$OUT" "Flow version not found: flowhere"
}

test_flow_configured_directories_before_path() {
  mkdir "$SANDBOX/site" "$SANDBOX/modules"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/site/flowx"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/modules/flowx"
  printf '%s\n' "OPMEXEC_FLOW_BIN_PATHS=(\"$SANDBOX/site\" PATH)" >> "$OPMEXEC_CONFIG"
  PATH="$SANDBOX/modules:$PATH" run "$OPMEXEC" -c @flow -v flowx A.DATA
  assert_contains "$OUT" "exe=$SANDBOX/site/flowx"

  PATH="$SANDBOX/modules:$PATH" run "$OPMEXEC" -c @flow -l
  assert_contains "$OUT" "  flowx  shadowed by $SANDBOX/site/flowx"
}

test_flow_skips_programs_that_are_not_opm_flow() {
  fake_other_flow "$SANDBOX/js" flowx
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowx"
  printf '%s\n' "OPMEXEC_FLOW_BIN_PATHS=(\"$SANDBOX/js\" \"$SANDBOX/bin\")" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -v flowx A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowx"

  run "$OPMEXEC" -c @flow -l
  assert_contains "$OUT" "  flowx     not OPM Flow, ignored"
  assert_contains "$OUT" "  flowx     2099.10"
}

test_flow_accepts_opm_simulators_without_version_option() {
  # e.g. flow_comp: OPM's parameter system rejects --version with its usage
  printf '%s\n' '#!/bin/sh' \
    '[ "$1" = --version ] && { exec >&2; echo "Option '"'"'--version'"'"' is missing a value."; echo "Usage: $0 [OPTIONS] [DECK_FILENAME]"; exit 0; }' \
    'echo "FLOW exe=$0"' > "$SANDBOX/bin/flow_comp"
  chmod +x "$SANDBOX/bin/flow_comp"
  run "$OPMEXEC" -c @flow -v _comp A.DATA
  assert_rc 0
  assert_contains "$OUT" "FLOW exe=$SANDBOX/bin/flow_comp"

  run "$OPMEXEC" -c @flow -l
  assert_contains "$OUT" "  flow_comp  unknown"
}

test_flow_reports_programs_that_are_not_opm_flow() {
  fake_other_flow "$SANDBOX/js" flowjs
  printf '%s\n' "OPMEXEC_FLOW_BIN_PATHS=(\"$SANDBOX/js\")" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -v flowjs A.DATA
  assert_rc 1
  assert_contains "$OUT" "Flow version not found: flowjs (searched OPMEXEC_FLOW_VERSIONS, then OPMEXEC_FLOW_BIN_PATHS: $SANDBOX/js); not OPM Flow: $SANDBOX/js/flowjs"

  run "$OPMEXEC" -c @flow -v "$SANDBOX/js/flowjs" A.DATA
  assert_rc 1
  assert_contains "$OUT" "Not OPM Flow: $SANDBOX/js/flowjs"

  run "$OPMEXEC" -c @flow -l
  assert_rc 1
  assert_contains "$OUT" "No OPM Flow found (OPMEXEC_FLOW_VERSIONS, then OPMEXEC_FLOW_BIN_PATHS: $SANDBOX/js)"
}

test_flow_relative_executable_path_made_absolute() {
  run "$OPMEXEC" -c @flow -v ../bin/flowtest A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowtest"
}

test_flow_list_keeps_search_order_when_checking_in_parallel() {
  # The first directory's checks are the slowest; it still comes first and
  # shadows the others
  local d
  for d in a b c; do
    mkdir "$SANDBOX/$d"
    cp "$SANDBOX/bin/flowtest" "$SANDBOX/$d/flowx"
  done
  sed -i '2i [ "$1" = --build-info ] \&\& sleep 0.5' "$SANDBOX/a/flowx"
  fake_other_flow "$SANDBOX/b" flowy
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/c/flowy"
  printf '%s\n' "OPMEXEC_FLOW_BIN_PATHS=(\"$SANDBOX/a\" \"$SANDBOX/b\" \"$SANDBOX/c\")" >> "$OPMEXEC_CONFIG"
  run "$OPMEXEC" -c @flow -l
  assert_rc 0
  assert_eq "$OUT" "   NAME   VERSION  HASH     TYPE     BUILT                PYTHON
$SANDBOX/a
   flowx  2099.10  abc1234  Release  2099-01-02 03:04:05  3.11
$SANDBOX/b
   flowx  shadowed by $SANDBOX/a/flowx
   flowy  not OPM Flow, ignored
$SANDBOX/c
   flowx  shadowed by $SANDBOX/a/flowx
   flowy  2099.10  abc1234  Release  2099-01-02 03:04:05  3.11"
}

# --- --flow-version: the version for every @flow without -v ---

test_flow_version_setting_applies_to_every_flow() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" --flow-version flowrc47 -c @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowrc47"
}

test_flow_version_setting_does_not_override_v() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" --flow-version flowrc47 -c @flow -v flowtest A.DATA
  assert_rc 0
  assert_contains "$OUT" "exe=$SANDBOX/bin/flowtest"
}

test_flow_version_setting_reaches_jobs() {
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  run "$OPMEXEC" --flow-version flowrc47 -c @wait @submit -o "$PWD/out.log" @mpi @flow A.DATA
  assert_rc 0
  assert_file_contains out.log "exe=$SANDBOX/bin/flowrc47"
}

test_flow_version_set_in_script_reaches_jobs() {
  # Also without export, and with opmexec::setup
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc47"
  cp "$SANDBOX/bin/flowtest" "$SANDBOX/bin/flowrc48"
  cat > sourcing.sh << EOF
source "$ROOT/lib/opmexec.sh" || exit 1
OPMEXEC_FLOW_VERSION=flowrc47
@wait @submit -o "\$PWD/one.log" @flow A.DATA
opmexec::setup --flow-version flowrc48
@wait @submit -o "\$PWD/two.log" @flow A.DATA
EOF
  run bash sourcing.sh
  assert_rc 0
  assert_file_contains one.log "exe=$SANDBOX/bin/flowrc47"
  assert_file_contains two.log "exe=$SANDBOX/bin/flowrc48"
}

test_flow_version_setting_used_by_flowpy() {
  run "$OPMEXEC" --dry-run --flow-version flowrc47 -c @flowpy script.py
  assert_contains "$OUT" "site-packages/flowrc47 "
}

test_flow_version_setting_needs_value_and_is_in_help() {
  run "$OPMEXEC" --flow-version
  assert_rc 1
  assert_contains "$OUT" "Option --flow-version needs a value"
  
  run "$OPMEXEC" -c @help @flow
  assert_contains "$OUT" "Flow version for every @flow and @flowpy without -v (default: flowtest)"
}

test_reserved_setting_names_rejected() {
  mkdir "$SANDBOX/directives"
  printf '%s\n' 'opmexec::directive hello "" "Hello"' 'opmexec::directive_setting queue HELLO_Q "Clash"' \
    '@hello() { echo hello; }' > "$SANDBOX/directives/hello.sh"
  export OPMEXEC_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$OPMEXEC" -c @hello
  assert_contains "$OUT" "@hello: --queue is reserved and cannot be a directive setting"
}
