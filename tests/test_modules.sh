#!/usr/bin/env bash
# SPDX-License-Identifier: GPL-3.0-or-later
# Copyright (C) 2026 OPM-OP AS
# Directive modules: registration, user extensions, overriding, protection

# Write a module file: write_module DIR NAME BODY
write_module() {
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/$2.sh"
}

HELLO_MODULE='runflow::directive hello "[NAME]" "Say hello"
runflow::command_hello() { _RUNFLOW_ARGV=(echo "hello ${1:-world}"); }
@hello() { runflow::command_hello "$@"; "${_RUNFLOW_ARGV[@]}"; }'

test_help_lists_core_bundled_and_user_directives() {
  write_module "$SANDBOX/directives" hello "$HELLO_MODULE"
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$RUNFLOW" -h
  assert_rc 0
  for name in @submit @wait @cancel @mpi @flow; do
    assert_contains "$OUT" "  $name "
  done
  [[ "$OUT" =~ "  @hello"\ +"Say hello" ]] || fail "no @hello in the help"
}

test_user_directive_runs_everywhere() {
  # Inline, under @mpi (via runflow::command_hello) and inside a job
  write_module "$SANDBOX/directives" hello "$HELLO_MODULE"
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/directives"

  run "$RUNFLOW" -c @hello you
  assert_rc 0
  assert_eq "$OUT" "hello you"

  run "$RUNFLOW" --dry-run -c @mpi -n 2 @hello you
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 2 echo hello\\ you"

  run "$RUNFLOW" -c @wait @submit -o "$PWD/out.log" @hello job
  assert_rc 0
  assert_file_contains out.log "hello job"
}

test_directives_option_loads_modules_for_jobs() {
  # --directives loads a module for this run and for its jobs
  write_module "$SANDBOX/mine" hello "$HELLO_MODULE"
  run "$RUNFLOW" --directives "$SANDBOX/mine" -c @wait @submit -o "$PWD/out.log" @hello opt
  assert_rc 0
  assert_file_contains out.log "hello opt"
}

test_extension_can_replace_flow() {
  write_module "$SANDBOX/site" flow 'runflow::directive flow "DECK" "Site Flow"
@flow() { echo "site flow $*"; }'
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/site" RUNFLOW_DEBUG=true
  run "$RUNFLOW" -c @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "site flow A.DATA"
  assert_contains "$OUT" "@flow from $SANDBOX/site/flow.sh replaces the one from"
}

test_later_directory_wins() {
  write_module "$SANDBOX/one" hello 'runflow::directive hello "" "One"
@hello() { echo one; }'
  write_module "$SANDBOX/two" hello 'runflow::directive hello "" "Two"
@hello() { echo two; }'
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/one:$SANDBOX/two"
  run "$RUNFLOW" -c @hello
  assert_eq "$OUT" "two"
}

test_core_directive_cannot_be_redefined() {
  write_module "$SANDBOX/evil" submit 'runflow::directive submit "" "Fake"
@submit() { echo "fake submit"; }'
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/evil"
  run "$RUNFLOW" -c @submit true
  assert_rc 0
  assert_contains "$OUT" "@submit is a core directive and cannot be redefined"
  assert_not_contains "$OUT" "fake submit"
  assert_not_contains "$OUT" "fake submit"
  [[ "$OUT" =~ $TEST_SCHEDULER:[0-9]+ ]] || fail "the real @submit did not run"
}

test_broken_module_is_reported_and_skipped() {
  write_module "$SANDBOX/directives" broken 'runflow::directive broken "" "Broken"
@broken() { echo "unclosed'
  write_module "$SANDBOX/directives" hello "$HELLO_MODULE"
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$RUNFLOW" -c @hello
  assert_contains "$OUT" "Could not load directive module: $SANDBOX/directives/broken.sh"
  assert_contains "$OUT" "hello world"
}

test_missing_directive_path_is_ignored() {
  export RUNFLOW_DIRECTIVE_PATH="$SANDBOX/does-not-exist"
  run "$RUNFLOW" -c @flow A.DATA
  assert_rc 0
}

test_directives_option_requires_existing_path() {
  run "$RUNFLOW" --directives "$SANDBOX/nope" -c true
  assert_rc 1
  assert_contains "$OUT" "Directive module or directory not found"
}
