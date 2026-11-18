#!/usr/bin/env bash
# Directive modules: registration, user extensions, overriding, protection

# Write a module file: write_module DIR NAME BODY
write_module() {
  mkdir -p "$1"
  printf '%s\n' "$3" > "$1/$2.sh"
}

HELLO_MODULE='flowrun::directive hello "[NAME]" "Say hello"
flowrun::command_hello() { _FLOWRUN_ARGV=(echo "hello ${1:-world}"); }
@hello() { flowrun::command_hello "$@"; "${_FLOWRUN_ARGV[@]}"; }'

test_help_lists_core_bundled_and_user_directives() {
  write_module "$SANDBOX/directives" hello "$HELLO_MODULE"
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$FLOWRUN" -h
  assert_rc 0
  for name in @submit @wait @cancel @mpi @flow; do
    assert_contains "$OUT" "  $name "
  done
  [[ "$OUT" =~ "  @hello"\ +"Say hello" ]] || fail "no @hello in the help"
}

test_user_directive_runs_everywhere() {
  # Inline, under @mpi (via flowrun::command_hello) and inside a job
  write_module "$SANDBOX/directives" hello "$HELLO_MODULE"
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/directives"

  run "$FLOWRUN" -c @hello you
  assert_rc 0
  assert_eq "$OUT" "hello you"

  run "$FLOWRUN" --dry-run -c @mpi -n 2 @hello you
  assert_rc 0
  assert_contains "$OUT" "run: mpirun -np 2 echo hello\\ you"

  run "$FLOWRUN" -c @wait @submit -o "$PWD/out.log" @hello job
  assert_rc 0
  assert_file_contains out.log "hello job"
}

test_directives_option_loads_modules_for_jobs() {
  # --directives loads a module for this run and for its jobs
  write_module "$SANDBOX/mine" hello "$HELLO_MODULE"
  run "$FLOWRUN" --directives "$SANDBOX/mine" -c @wait @submit -o "$PWD/out.log" @hello opt
  assert_rc 0
  assert_file_contains out.log "hello opt"
}

test_extension_can_replace_flow() {
  write_module "$SANDBOX/site" flow 'flowrun::directive flow "DECK" "Site Flow"
@flow() { echo "site flow $*"; }'
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/site" FLOWRUN_DEBUG=true
  run "$FLOWRUN" -c @flow A.DATA
  assert_rc 0
  assert_contains "$OUT" "site flow A.DATA"
  assert_contains "$OUT" "@flow from $SANDBOX/site/flow.sh replaces the one from"
}

test_later_directory_wins() {
  write_module "$SANDBOX/one" hello 'flowrun::directive hello "" "One"
@hello() { echo one; }'
  write_module "$SANDBOX/two" hello 'flowrun::directive hello "" "Two"
@hello() { echo two; }'
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/one:$SANDBOX/two"
  run "$FLOWRUN" -c @hello
  assert_eq "$OUT" "two"
}

test_core_directive_cannot_be_redefined() {
  write_module "$SANDBOX/evil" submit 'flowrun::directive submit "" "Fake"
@submit() { echo "fake submit"; }'
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/evil"
  run "$FLOWRUN" -c @submit true
  assert_rc 0
  assert_contains "$OUT" "@submit is a core directive and cannot be redefined"
  assert_not_contains "$OUT" "fake submit"
  assert_not_contains "$OUT" "fake submit"
  [[ "$OUT" =~ $TEST_SCHEDULER:[0-9]+ ]] || fail "the real @submit did not run"
}

test_broken_module_is_reported_and_skipped() {
  write_module "$SANDBOX/directives" broken 'flowrun::directive broken "" "Broken"
@broken() { echo "unclosed'
  write_module "$SANDBOX/directives" hello "$HELLO_MODULE"
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/directives"
  run "$FLOWRUN" -c @hello
  assert_contains "$OUT" "Could not load directive module: $SANDBOX/directives/broken.sh"
  assert_contains "$OUT" "hello world"
}

test_missing_directive_path_is_ignored() {
  export FLOWRUN_DIRECTIVE_PATH="$SANDBOX/does-not-exist"
  run "$FLOWRUN" -c @flow A.DATA
  assert_rc 0
}

test_directives_option_requires_existing_path() {
  run "$FLOWRUN" --directives "$SANDBOX/nope" -c true
  assert_rc 1
  assert_contains "$OUT" "Directive module or directory not found"
}
